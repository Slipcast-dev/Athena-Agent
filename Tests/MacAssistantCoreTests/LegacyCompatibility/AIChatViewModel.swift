// Историческая модель оставлена только в тестовом target для проверки
// совместимости сохранённых диалогов и прежних регрессий. В приложение не входит.
import Foundation
import MacAssistantCore

/// История и жизненный цикл запроса принадлежат модели, а не SwiftUI-экрану.
@MainActor
final class AIChatViewModel: ObservableObject {
    @Published private(set) var isGenerating = false
    @Published private(set) var isLoaded = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var conversations: [ChatConversation] = []
    @Published var profiles: [AIProviderProfile] = []
    @Published var selectedProfileID: UUID?
    @Published var modelID = ""
    @Published var input = ""
    @Published private(set) var conversation = ChatConversation(title: "Новый диалог")
    @Published private(set) var generatingMessageID: UUID?
    private let ai: any AIProviding
    private let manager: any AIProfileManaging
    private let history: ChatHistoryStore
    private var requestTask: Task<Void, Never>?
    private var retryContext: [ChatMessage]?

    init(ai: any AIProviding, manager: any AIProfileManaging, history: ChatHistoryStore = .init()) {
        self.ai = ai
        self.manager = manager
        self.history = history
    }

    var canRetry: Bool { retryContext != nil && !isGenerating }
    var selectedProfileName: String { selectedProfile?.name ?? "Athena" }
    var canSend: Bool {
        isLoaded && !isGenerating && selectedProfile != nil
            && !modelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// При выборе другого провайдера модель меняется на его defaultModelID,
    /// чтобы случайно не отправить идентификатор от предыдущего API.
    func selectProfile(_ id: UUID?) {
        guard !isGenerating else { return }
        selectedProfileID = id
        modelID = selectedProfile?.defaultModelID ?? ""
    }

    func load() async {
        profiles = await manager.profiles()
        if !profiles.contains(where: { $0.id == selectedProfileID }) {
            selectedProfileID = profiles.first?.id
            modelID = profiles.first?.defaultModelID ?? ""
        }
        // Повторное появление View не должно заменять текущую переписку.
        guard !isLoaded else { return }
        conversations = await history.load().sorted { $0.updatedAt > $1.updatedAt }
        if let latest = conversations.first {
            conversation = latest
            retryContext = latest.retryMessages
        }
        isLoaded = true
    }

    func selectConversation(_ id: UUID) {
        guard !isGenerating, let saved = conversations.first(where: { $0.id == id }) else { return }
        conversation = saved
        retryContext = saved.retryMessages
        errorMessage = nil
    }

    func newConversation() {
        guard !isGenerating else { return }
        conversation = ChatConversation(title: "Новый диалог")
        input = ""
        retryContext = nil
        errorMessage = nil
    }

    func send() {
        guard canSend else { return }
        conversation.messages.append(ChatMessage(role: .user, content: input))
        input = ""
        retryContext = conversation.messages
        conversation.retryMessages = retryContext
        beginRequest()
    }

    func retry() {
        guard canRetry, let context = retryContext, selectedProfile != nil, !modelID.isEmpty else { return }
        // Убираем только незавершённый ответ; исходный запрос не дублируется.
        conversation.messages = context
        beginRequest()
    }

    private var selectedProfile: AIProviderProfile? { profiles.first { $0.id == selectedProfileID } }

    private func beginRequest() {
        guard let profile = selectedProfile, let messages = retryContext else { return }
        let requestModelID = modelID
        let assistantID = UUID()
        conversation.messages.append(ChatMessage(id: assistantID, role: .assistant, content: ""))
        generatingMessageID = assistantID
        isGenerating = true
        errorMessage = nil
        requestTask = Task { [weak self] in
            guard let self else { return }
            do {
                // Сохраняем вопрос до сети, чтобы ошибка или отмена не теряла его.
                try await persist()
                try Task.checkCancellation()
                if let streaming = ai as? any AIStreamingProviding, profile.kind != .ollama {
                    for try await chunk in streaming.stream(messages: messages, using: profile, modelID: requestModelID) {
                        try Task.checkCancellation()
                        append(chunk, to: assistantID)
                    }
                } else {
                    let reply = try await ai.send(messages: messages, using: profile, modelID: requestModelID)
                    try Task.checkCancellation()
                    append(reply.content, to: assistantID)
                }
                try Task.checkCancellation()
                retryContext = nil
                conversation.retryMessages = nil
            } catch is CancellationError {
                errorMessage = "Ответ остановлен. Можно повторить запрос."
            } catch {
                errorMessage = "Не удалось получить или сохранить ответ. Можно повторить запрос."
            }
            // Частичный ответ сохраняется и остаётся видимым при ошибке.
            do { try await persist() }
            catch { errorMessage = "Не удалось сохранить переписку." }
            generatingMessageID = nil
            isGenerating = false
            requestTask = nil
        }
    }

    private func append(_ text: String, to id: UUID) {
        guard let index = conversation.messages.firstIndex(where: { $0.id == id }) else { return }
        let old = conversation.messages[index]
        conversation.messages[index] = ChatMessage(id: id, role: old.role, content: old.content + text, createdAt: old.createdAt)
    }

    private func persist() async throws {
        conversation.title = conversation.messages.first?.content.prefix(40).description ?? "Диалог"
        conversation.updatedAt = .now
        try await history.upsert(conversation)
        conversations = await history.load()
    }

    func cancel() { requestTask?.cancel() }
    /// Позволяет тестировать завершение без таймеров и случайных задержек.
    func waitForCompletion() async { await requestTask?.value }
}

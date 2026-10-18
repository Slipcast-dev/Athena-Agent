// Историческая модель оставлена только в тестовом target для проверки
// совместимости сохранённых диалогов и прежних регрессий. В приложение не входит.
import Foundation
import MacAssistantCore

/// Согласие связано с конкретным профилем и его API-адресом.
@MainActor
final class DiagnosticAIConsentViewModel: ObservableObject {
    @Published private(set) var profiles: [AIProviderProfile] = []
    @Published var selectedProfileID: UUID? {
        didSet {
            guard selectedProfileID != oldValue else { return }
            consent = false
            result = ""
            modelID = selectedProfile?.defaultModelID ?? ""
        }
    }
    @Published var consent = false
    @Published var modelID = ""
    @Published private(set) var result = ""
    @Published private(set) var isSending = false
    private let ai: any AIProviding
    private let manager: any AIProfileManaging
    private let report: DiagnosticReport

    init(report: DiagnosticReport, ai: any AIProviding, manager: any AIProfileManaging) {
        self.report = report
        self.ai = ai
        self.manager = manager
    }

    var preview: String { DiagnosticReportRedactor.text(for: report) }
    var selectedProfile: AIProviderProfile? { profiles.first { $0.id == selectedProfileID } }
    var canSend: Bool {
        consent && selectedProfile != nil && !modelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isSending
    }

    func load() async {
        let previous = selectedProfile
        profiles = await manager.profiles()
        if !profiles.contains(where: { $0.id == selectedProfileID }) { selectedProfileID = profiles.first?.id }
        // Адрес мог измениться при том же ID: прежнее согласие уже неприменимо.
        if previous != selectedProfile { consent = false }
        if modelID.isEmpty { modelID = selectedProfile?.defaultModelID ?? "" }
    }

    func send() async {
        guard canSend, let recipient = selectedProfile else { return }
        let requestedModel = modelID
        isSending = true
        consent = false
        defer { isSending = false }
        do {
            let reply = try await ai.send(messages: [
                ChatMessage(role: .system, content: "Проанализируй только предоставленный диагностический отчёт на русском языке."),
                ChatMessage(role: .user, content: preview)
            ], using: recipient, modelID: requestedModel)
            result = reply.content
        } catch {
            result = "Не удалось отправить отчёт. Проверьте провайдера и повторно подтвердите отправку."
        }
    }
}

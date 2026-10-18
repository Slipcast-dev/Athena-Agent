import XCTest
import Combine
import MacAssistantCore
@testable import MacAssistant

/// Управляемый поток даёт проверять UI-состояния до завершения сети без sleeps.
private struct ControlledStreamingAI: AIStreamingProviding {
    let response: AsyncThrowingStream<String, Error>
    func availableModels(for profile: AIProviderProfile) async throws -> [AIModel] { [] }
    func send(messages: [ChatMessage], using profile: AIProviderProfile, modelID: String) async throws -> ChatMessage {
        ChatMessage(role: .assistant, content: "Готово")
    }
    func stream(messages: [ChatMessage], using profile: AIProviderProfile, modelID: String) -> AsyncThrowingStream<String, Error> { response }
}

private actor TestProfiles: AIProfileManaging {
    var values: [AIProviderProfile]
    init(_ values: [AIProviderProfile]) { self.values = values }
    func profiles() -> [AIProviderProfile] { values }
    func save(profile: AIProviderProfile, apiKey: String?) {
        values.removeAll { $0.id == profile.id }
        values.append(profile)
    }
    func delete(profileID: UUID) { values.removeAll { $0.id == profileID } }
}

private actor RecordingAI: AIProviding {
    var recipients: [AIProviderProfile] = []
    func availableModels(for profile: AIProviderProfile) -> [AIModel] { [] }
    func send(messages: [ChatMessage], using profile: AIProviderProfile, modelID: String) -> ChatMessage {
        recipients.append(profile)
        return ChatMessage(role: .assistant, content: "Готово")
    }
}

@MainActor
final class ChatAndConsentTests: XCTestCase {
    func testComposerReadinessAndProfileSelectionUseDefaultModel() async {
        var first = profile("Первый API")
        first.defaultModelID = "first-model"
        var second = profile("Второй API")
        second.defaultModelID = "second-model"
        let suite = "ChatVM.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let vm = AIChatViewModel(ai: RecordingAI(), manager: TestProfiles([first, second]), history: ChatHistoryStore(defaults: defaults))
        XCTAssertFalse(vm.canSend)
        await vm.load()
        vm.input = " \n "
        XCTAssertFalse(vm.canSend)
        vm.input = "Вопрос"
        XCTAssertTrue(vm.canSend)
        vm.selectProfile(second.id)
        XCTAssertEqual(vm.modelID, "second-model")
        XCTAssertEqual(vm.selectedProfileName, "Второй API")
        vm.modelID = "  "
        XCTAssertFalse(vm.canSend)
        vm.selectProfile(nil)
        XCTAssertFalse(vm.canSend)
        XCTAssertTrue(vm.modelID.isEmpty)
        XCTAssertEqual(vm.selectedProfileName, "Athena")
    }

    private func profile(_ name: String = "Первый") -> AIProviderProfile {
        AIProviderProfile(name: name, kind: .openAICompatible, baseURL: URL(string: "https://example.com/v1")!, defaultModelID: "test-model")
    }

    func testRestoresLatestAndSavesOtherConversations() async throws {
        let suite = "ChatVM.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = ChatHistoryStore(defaults: defaults)
        let old = ChatConversation(title: "Старый", updatedAt: .distantPast)
        let latest = ChatConversation(title: "Последний", messages: [ChatMessage(role: .user, content: "Привет")])
        try await store.save([old, latest])
        let vm = AIChatViewModel(ai: RecordingAI(), manager: TestProfiles([profile()]), history: store)
        await vm.load()
        XCTAssertEqual(vm.conversation.id, latest.id)
        vm.input = "Продолжить"
        vm.send()
        await vm.waitForCompletion()
        let restored = await store.load()
        XCTAssertEqual(restored.count, 2)
        XCTAssertEqual(restored.first { $0.id == old.id }, old)
        XCTAssertEqual(restored.first { $0.id == latest.id }?.messages.last?.content, "Готово")
        vm.newConversation()
        vm.input = "Новая тема"
        vm.send()
        await vm.waitForCompletion()
        let all = await store.load()
        XCTAssertEqual(all.count, 3)
    }

    func testStreamingFailureKeepsMessagesAndRetryDoesNotDuplicateQuestion() async throws {
        let suite = "ChatVM.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = ChatHistoryStore(defaults: defaults)
        let (stream, continuation) = AsyncThrowingStream<String, Error>.makeStream()
        let vm = AIChatViewModel(ai: ControlledStreamingAI(response: stream), manager: TestProfiles([profile()]), history: store)
        await vm.load()
        vm.input = "Вопрос"
        vm.send()
        XCTAssertTrue(vm.isGenerating)
        XCTAssertEqual(vm.conversation.messages.first?.content, "Вопрос")
        XCTAssertEqual(vm.generatingMessageID, vm.conversation.messages.last?.id)
        vm.input = "Не должен отправиться второй раз"
        vm.send()
        XCTAssertEqual(vm.conversation.messages.filter { $0.role == .user }.count, 1)
        let chunkVisible = expectation(description: "Часть ответа видна до завершения потока")
        let observation = vm.$conversation.sink { conversation in
            if conversation.messages.last?.content == "Частичный ответ" { chunkVisible.fulfill() }
        }
        continuation.yield("Частичный ответ")
        await fulfillment(of: [chunkVisible], timeout: 2)
        observation.cancel()
        XCTAssertTrue(vm.isGenerating)
        XCTAssertEqual(vm.conversation.messages.last?.content, "Частичный ответ")
        continuation.finish(throwing: ServiceError.unavailable(feature: "Тест"))
        await vm.waitForCompletion()
        XCTAssertFalse(vm.isGenerating)
        XCTAssertEqual(vm.conversation.messages.last?.content, "Частичный ответ")
        XCTAssertNotNil(vm.errorMessage)
        XCTAssertTrue(vm.canRetry)
        let restored = await store.load()
        XCTAssertEqual(restored.first?.messages, vm.conversation.messages)
        let reopened = AIChatViewModel(ai: RecordingAI(), manager: TestProfiles([profile()]), history: store)
        await reopened.load()
        XCTAssertTrue(reopened.canRetry)
        reopened.retry()
        await reopened.waitForCompletion()
        XCTAssertEqual(reopened.conversation.messages.last?.content, "Готово")
        XCTAssertEqual(reopened.conversation.messages.filter { $0.role == .user }.count, 1)
        XCTAssertFalse(reopened.canRetry)
        vm.retry()
        await vm.waitForCompletion()
        XCTAssertEqual(vm.conversation.messages.filter { $0.role == .user }.count, 1)
    }

    func testCancellationRetainsQuestionAndAllowsRetry() async {
        let suite = "ChatVM.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let (stream, _) = AsyncThrowingStream<String, Error>.makeStream()
        let store = ChatHistoryStore(defaults: defaults)
        let vm = AIChatViewModel(ai: ControlledStreamingAI(response: stream), manager: TestProfiles([profile()]), history: store)
        await vm.load()
        vm.input = "Сохранить вопрос"
        vm.send()
        vm.cancel()
        await vm.waitForCompletion()
        XCTAssertFalse(vm.isGenerating)
        XCTAssertTrue(vm.canRetry)
        let saved = await store.load()
        XCTAssertEqual(saved.first?.messages.first?.content, "Сохранить вопрос")
    }

    func testRecipientChangeResetsConsentAndUsesSelectedAPI() async throws {
        let first = profile()
        var second = profile("Второй")
        second.baseURL = URL(string: "https://other.example/v1")!
        let manager = TestProfiles([first, second])
        let ai = RecordingAI()
        let metrics = SystemMetrics(cpuUsagePercent: 10, totalMemoryBytes: 1, usedMemoryBytes: 1, availableMemoryBytes: nil, memoryPressure: nil, totalStorageBytes: 100, availableStorageBytes: 50)
        let report = DiagnosticReport(applicationVersion: "0.1.1", operatingSystemVersion: "macOS", metrics: metrics, findings: [], status: .completed)
        let vm = DiagnosticAIConsentViewModel(report: report, ai: ai, manager: manager)
        await vm.load()
        vm.consent = true
        vm.selectedProfileID = second.id
        XCTAssertFalse(vm.consent)
        XCTAssertEqual(vm.selectedProfile?.baseURL, second.baseURL)
        await vm.send()
        var sent = await ai.recipients
        XCTAssertTrue(sent.isEmpty)
        vm.consent = true
        await vm.send()
        sent = await ai.recipients
        XCTAssertEqual(sent, [second])
        XCTAssertFalse(vm.consent)
        vm.consent = true
        second.baseURL = URL(string: "https://changed.example/v1")!
        await manager.save(profile: second, apiKey: nil)
        await vm.load()
        XCTAssertFalse(vm.consent)
        XCTAssertEqual(vm.selectedProfile?.baseURL, second.baseURL)
    }
}

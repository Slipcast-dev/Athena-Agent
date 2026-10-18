import XCTest
@testable import MacAssistantCore

final class ChatHistoryTests: XCTestCase {
    func testCorruptHistoryCannotBeOverwrittenByUpsert() async throws {
        let suite = "ChatHistoryTests.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let original = Data("invalid JSON history".utf8)
        defaults.set(original, forKey: "chatConversations")
        do {
            try await ChatHistoryStore(defaults: defaults).upsert(ChatConversation(title: "Новый"))
            XCTFail("Повреждённая история должна остановить запись")
        } catch { }
        XCTAssertEqual(defaults.data(forKey: "chatConversations"), original)
    }

    func testLegacyConversationWithoutRetryContextStillDecodes() throws {
        let original = ChatConversation(title: "Старый формат")
        let data = try JSONEncoder().encode(original)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object.removeValue(forKey: "retryMessages")
        let restored = try JSONDecoder().decode(ChatConversation.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertEqual(restored, original)
        XCTAssertNil(restored.retryMessages)
    }

    func testUpdatingOneConversationRetainsOthersAfterReopening() async throws {
        let suite = "ChatHistoryTests.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = ChatHistoryStore(defaults: defaults)
        var first = ChatConversation(title: "Первый")
        let second = ChatConversation(title: "Второй")
        try await store.upsert(first)
        try await store.upsert(second)
        first.messages.append(ChatMessage(role: .user, content: "Продолжение"))
        try await store.upsert(first)
        let restored = await ChatHistoryStore(defaults: UserDefaults(suiteName: suite)!).load()
        XCTAssertEqual(restored.count, 2)
        XCTAssertEqual(restored.first { $0.id == first.id }, first)
        XCTAssertEqual(restored.first { $0.id == second.id }, second)
    }

    func testHistoryRoundTripDoesNotContainProviderSecrets() async throws {
        let suite = "ChatHistoryTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = ChatHistoryStore(defaults: defaults)
        let conversation = ChatConversation(title: "Тест", messages: [ChatMessage(role: .user, content: "Привет")])
        try await store.save([conversation])
        let restored = await store.load()
        XCTAssertEqual(restored, [conversation])
    }
}

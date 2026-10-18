import XCTest
import Security
@testable import MacAssistantCore

final class AIHardeningTests: XCTestCase {
    func testStreamRejectsHTTPBeforeLoadingKeyOrStartingNetwork() async {
        let suite = "AIHardening.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let ai = NetworkAIProvider(manager: AIProviderManager(defaults: defaults))
        let profile = AIProviderProfile(name: "Invalid", kind: .openAICompatible,
                                        baseURL: URL(string: "http://example.invalid/v1")!)
        do {
            for try await _ in ai.stream(messages: [], using: profile, modelID: "test") { }
            XCTFail("HTTP должен быть отклонён до проверки отсутствующего ключа")
        } catch { XCTAssertEqual(error as? AIProviderError, .insecureEndpoint) }
    }

    func testTruncatedStreamRequiresRetry() throws {
        var decoder = OpenAIStreamDecoder()
        XCTAssertEqual(try decoder.consume(#"{"choices":[{"delta":{"content":"Часть ответа"}}]}"#), "Часть ответа")
        XCTAssertThrowsError(try decoder.validateCompletion())
    }

    func testDoneAndFinishReasonAreExplicitCompletion() throws {
        var done = OpenAIStreamDecoder()
        _ = try done.consume("[DONE]")
        XCTAssertNoThrow(try done.validateCompletion())
        var finish = OpenAIStreamDecoder()
        _ = try finish.consume(#"{"choices":[{"delta":{},"finish_reason":"stop"}]}"#)
        XCTAssertNoThrow(try finish.validateCompletion())
    }

    func testServiceFramesAreAllowedButMalformedDataIsNotIgnored() throws {
        var decoder = OpenAIStreamDecoder()
        XCTAssertNil(try decoder.consume(#"{"choices":[{"delta":{"role":"assistant"}}]}"#))
        XCTAssertNil(try decoder.consume(#"{"choices":[],"usage":{"total_tokens":10}}"#))
        XCTAssertThrowsError(try decoder.consume("broken-json"))
        XCTAssertThrowsError(try decoder.consume(#"{"error":{"message":"failed"}}"#))
        XCTAssertThrowsError(try decoder.consume(#"{"choices":[]}"#))
        XCTAssertThrowsError(try decoder.validateCompletion())
    }

    func testKeychainFailureKeepsPreviousValueAndDoesNotAdd() throws {
        let writer = FakeKeychainWriter(updateStatus: errSecInteractionNotAllowed)
        let store = KeychainSecretStore(writer: writer)
        XCTAssertThrowsError(try store.save(secret: "replacement-fixture", account: "test-account"))
        XCTAssertEqual(writer.value, Data("previous-fixture".utf8))
        XCTAssertEqual(writer.addCount, 0)
    }

    func testKeychainUpdatesExistingEntryWithoutAdding() throws {
        let writer = FakeKeychainWriter(updateStatus: errSecSuccess)
        try KeychainSecretStore(writer: writer).save(secret: "replacement-fixture", account: "test-account")
        XCTAssertEqual(writer.value, Data("replacement-fixture".utf8))
        XCTAssertEqual(writer.addCount, 0)
    }

    func testKeychainAddsOnlyWhenEntryIsMissing() throws {
        let writer = FakeKeychainWriter(updateStatus: errSecItemNotFound)
        try KeychainSecretStore(writer: writer).save(secret: "new-fixture", account: "test-account")
        XCTAssertEqual(writer.value, Data("new-fixture".utf8))
        XCTAssertEqual(writer.addCount, 1)
        let failed = FakeKeychainWriter(updateStatus: errSecItemNotFound, addStatus: errSecNotAvailable)
        XCTAssertThrowsError(try KeychainSecretStore(writer: failed).save(secret: "fixture", account: "test-account"))
    }
}

/// Подменяется только системная запись: тест не меняет настоящий Keychain.
private final class FakeKeychainWriter: KeychainWriting, @unchecked Sendable {
    private let lock = NSLock()
    private let updateStatus: OSStatus
    private let addStatus: OSStatus
    private(set) var value = Data("previous-fixture".utf8)
    private(set) var addCount = 0
    init(updateStatus: OSStatus, addStatus: OSStatus = errSecSuccess) {
        self.updateStatus = updateStatus
        self.addStatus = addStatus
    }
    func update(query: [String: Any], attributes: [String: Any]) -> OSStatus {
        lock.lock(); defer { lock.unlock() }
        if updateStatus == errSecSuccess { value = attributes[kSecValueData as String] as! Data }
        return updateStatus
    }
    func add(query: [String: Any]) -> OSStatus {
        lock.lock(); defer { lock.unlock() }
        addCount += 1
        if addStatus == errSecSuccess { value = query[kSecValueData as String] as! Data }
        return addStatus
    }
}

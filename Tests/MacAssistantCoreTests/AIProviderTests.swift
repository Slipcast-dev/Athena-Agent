import XCTest
@testable import MacAssistantCore

final class AIProviderTests: XCTestCase {
    func testCloudProfileRequiresHTTPS() {
        let profile = AIProviderProfile(name: "OpenAI", kind: .openAI, baseURL: URL(string: "http://api.openai.com/v1")!)
        XCTAssertThrowsError(try AIEndpointValidator.validate(profile)) { error in
            XCTAssertEqual(error as? AIProviderError, .insecureEndpoint)
        }
    }

    func testOllamaAllowsOnlyLoopbackHTTP() throws {
        let local = AIProviderProfile(name: "Ollama", kind: .ollama, baseURL: URL(string: "http://localhost:11434/api")!)
        XCTAssertNoThrow(try AIEndpointValidator.validate(local))
        let remote = AIProviderProfile(name: "Remote", kind: .ollama, baseURL: URL(string: "http://example.com:11434/api")!)
        XCTAssertThrowsError(try AIEndpointValidator.validate(remote))
    }

    func testManagerStoresProfileWithoutSecretInDefaults() async throws {
        let suite = "AIProviderTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let secrets = InMemorySecretStore()
        let manager = AIProviderManager(defaults: defaults, secretStore: secrets)
        let profile = AIProviderProfile(name: "Provider", kind: .openAI, baseURL: URL(string: "https://api.example.com/v1")!)

        try await manager.save(profile: profile, apiKey: "test-secret-value")

        let stored = await manager.profiles()
        XCTAssertEqual(stored.count, 1)
        XCTAssertNotNil(stored.first?.keychainAccount)
        XCTAssertFalse((defaults.data(forKey: "aiProviderProfiles").flatMap { String(data: $0, encoding: .utf8) } ?? "").contains("test-secret-value"))
        let savedKey = try await manager.apiKey(for: stored[0])
        XCTAssertEqual(savedKey, "test-secret-value")
    }
}

private final class InMemorySecretStore: SecretStoring, @unchecked Sendable {
    private var values: [String: String] = [:]
    private let lock = NSLock()

    func save(secret: String, account: String) throws {
        lock.lock(); defer { lock.unlock() }
        values[account] = secret
    }
    func load(account: String) throws -> String? {
        lock.lock(); defer { lock.unlock() }
        return values[account]
    }
    func delete(account: String) throws {
        lock.lock(); defer { lock.unlock() }
        values.removeValue(forKey: account)
    }
}

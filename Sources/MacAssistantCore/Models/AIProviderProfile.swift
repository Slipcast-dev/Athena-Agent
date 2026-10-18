import Foundation

public struct AIProviderProfile: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public var name: String
    public var kind: AIProviderKind
    public var baseURL: URL
    /// Идентификатор ключа, а не сам ключ. Секрет хранится отдельно в Keychain.
    public var keychainAccount: String?
    public var defaultModelID: String?

    public init(
        id: UUID = UUID(),
        name: String,
        kind: AIProviderKind,
        baseURL: URL,
        keychainAccount: String? = nil,
        defaultModelID: String? = nil
    ) {
        self.id = id
        self.name = name
        self.kind = kind
        self.baseURL = baseURL
        self.keychainAccount = keychainAccount
        self.defaultModelID = defaultModelID
    }
}

public enum AIProviderKind: String, Codable, CaseIterable, Sendable {
    case openAI
    case openRouter
    case deepSeek
    case openAICompatible
    case ollama
}

public struct AIModel: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let displayName: String
    public let supportsStreaming: Bool

    public init(id: String, displayName: String, supportsStreaming: Bool) {
        self.id = id
        self.displayName = displayName
        self.supportsStreaming = supportsStreaming
    }
}

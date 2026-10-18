import Foundation
import Security

public protocol SecretStoring: Sendable {
    func save(secret: String, account: String) throws
    func load(account: String) throws -> String?
    func delete(account: String) throws
}

/// Единственное хранилище производственных API-ключей. UserDefaults намеренно
/// не используется: в нём сохраняются только Codable-профили без секретов.
public struct KeychainSecretStore: SecretStoring {
    private let service = "com.macassistant.api-keys"
    private let writer: any KeychainWriting
    public init() { writer = SystemKeychainWriter() }
    /// Системная граница подменяется только в тестах ошибок Keychain.
    init(writer: any KeychainWriting) { self.writer = writer }

    public func save(secret: String, account: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: Data(secret.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlocked
        ]
        // SecItemUpdate сохраняет старое значение при ошибке обновления.
        // Добавляем запись только когда она действительно отсутствует.
        let status = writer.update(query: query, attributes: attributes)
        if status == errSecItemNotFound {
            let addition = query.merging(attributes) { _, new in new }
            guard writer.add(query: addition) == errSecSuccess else { throw AIProviderError.secretStorageFailed }
        } else if status != errSecSuccess {
            throw AIProviderError.secretStorageFailed
        }
    }

    public func load(account: String) throws -> String? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account, kSecReturnData as String: true]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data, let value = String(data: data, encoding: .utf8) else { throw AIProviderError.secretStorageFailed }
        return value
    }

    public func delete(account: String) throws {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw AIProviderError.secretStorageFailed }
    }
}

protocol KeychainWriting: Sendable {
    func update(query: [String: Any], attributes: [String: Any]) -> OSStatus
    func add(query: [String: Any]) -> OSStatus
}

private struct SystemKeychainWriter: KeychainWriting {
    func update(query: [String: Any], attributes: [String: Any]) -> OSStatus {
        SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
    }
    func add(query: [String: Any]) -> OSStatus { SecItemAdd(query as CFDictionary, nil) }
}

public enum AIEndpointValidator {
    public static func validate(_ profile: AIProviderProfile) throws {
        guard let host = profile.baseURL.host, !host.isEmpty else { throw AIProviderError.invalidEndpoint }
        if profile.kind == .ollama {
            guard profile.baseURL.scheme == "http" || profile.baseURL.scheme == "https" else { throw AIProviderError.invalidEndpoint }
            guard host == "localhost" || host == "127.0.0.1" || host == "::1" else { throw AIProviderError.insecureLocalEndpoint }
        } else if profile.baseURL.scheme != "https" {
            throw AIProviderError.insecureEndpoint
        }
    }
}

public actor AIProviderManager: AIProfileManaging {
    private let defaults: UserDefaults
    private let secretStore: any SecretStoring
    private let storageKey = "aiProviderProfiles"

    public init(defaults: UserDefaults = .standard, secretStore: any SecretStoring = KeychainSecretStore()) {
        self.defaults = defaults
        self.secretStore = secretStore
    }

    public func profiles() -> [AIProviderProfile] {
        guard let data = defaults.data(forKey: storageKey), let profiles = try? JSONDecoder().decode([AIProviderProfile].self, from: data) else { return [] }
        return profiles.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    public func save(profile: AIProviderProfile, apiKey: String?) throws {
        try AIEndpointValidator.validate(profile)
        var stored = profile
        if let apiKey, !apiKey.isEmpty {
            let account = "provider-\(profile.id.uuidString.lowercased())"
            try secretStore.save(secret: apiKey, account: account)
            stored.keychainAccount = account
        }
        var current = profiles().filter { $0.id != stored.id }
        current.append(stored)
        defaults.set(try JSONEncoder().encode(current), forKey: storageKey)
    }

    public func delete(profileID: UUID) throws {
        guard let profile = profiles().first(where: { $0.id == profileID }) else { return }
        if let account = profile.keychainAccount { try secretStore.delete(account: account) }
        defaults.set(try JSONEncoder().encode(profiles().filter { $0.id != profileID }), forKey: storageKey)
    }

    public func apiKey(for profile: AIProviderProfile) throws -> String? {
        guard let account = profile.keychainAccount else { return nil }
        return try secretStore.load(account: account)
    }
}

public enum AIProviderError: LocalizedError, Equatable, Sendable {
    case invalidEndpoint, insecureEndpoint, insecureLocalEndpoint, secretStorageFailed
    case missingAPIKey, unauthorized, rateLimited, server(status: Int), invalidResponse, network

    public var errorDescription: String? {
        switch self {
        case .invalidEndpoint: "Укажите корректный адрес API."
        case .insecureEndpoint: "Для облачного провайдера требуется HTTPS."
        case .insecureLocalEndpoint: "HTTP разрешён только для локального Ollama на loopback-адресе."
        case .secretStorageFailed: "Не удалось безопасно сохранить ключ в Keychain."
        case .missingAPIKey: "Для выбранного провайдера не задан API-ключ."
        case .unauthorized: "Провайдер отклонил API-ключ."
        case .rateLimited: "Превышен лимит запросов провайдера."
        case .server: "Провайдер вернул ошибку сервера."
        case .invalidResponse: "Провайдер вернул неподдерживаемый ответ."
        case .network: "Не удалось подключиться к провайдеру."
        }
    }
}

import Foundation

/// Категория операции, которую внешний агент запрашивает у приложения.
/// Разделение на уровни не позволяет расширить мост опасной командой незаметно.
public enum AgentPermissionLevel: String, Codable, CaseIterable, Sendable {
    /// Операция возвращает только обезличенные локальные сведения и не меняет систему.
    case readOnly
    /// Операция затрагивает данные или сеть, поэтому требует отдельного согласия пользователя.
    case controlled
    /// Операция способна изменить систему и в MVP через MCP не поддерживается.
    case confirmationRequired
}

/// Описание доступной команды для интерфейса и для ответа `tools/list` протокола MCP.
public struct AgentCommand: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let title: String
    public let permissionLevel: AgentPermissionLevel
    public let description: String

    public init(id: String, title: String, permissionLevel: AgentPermissionLevel, description: String) {
        self.id = id
        self.title = title
        self.permissionLevel = permissionLevel
        self.description = description
    }
}

/// Запрос не содержит произвольной команды оболочки: идентификатор выбирается из allowlist.
public struct AgentCommandRequest: Codable, Equatable, Sendable {
    public let commandID: String

    public init(commandID: String) {
        self.commandID = commandID
    }
}

/// Текстовый результат предназначен для MCP и не включает имена файлов, ключи или идентификаторы устройства.
public struct AgentCommandResult: Codable, Equatable, Sendable {
    public let commandID: String
    public let text: String

    public init(commandID: String, text: String) {
        self.commandID = commandID
        self.text = text
    }
}

/// Поддерживаемые клиенты, которые могут запускать локальный MCP-исполнитель.
public enum MCPClient: String, Codable, CaseIterable, Sendable, Identifiable {
    case codex
    case deepSeekHarness

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .codex: "Codex"
        case .deepSeekHarness: "DeepSeek Harness"
        }
    }
}

/// Состояние подключения намеренно не содержит пути, секреты или вывод сторонних процессов.
public enum MCPConnectionStatus: Equatable, Sendable {
    case notConfigured
    case configured
    case unavailable(reason: String)

    public var title: String {
        switch self {
        case .notConfigured: "Не подключён"
        case .configured: "Подключён"
        case let .unavailable(reason): reason
        }
    }
}

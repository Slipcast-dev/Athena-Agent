import Foundation
import EcosystemClientAdapters

/// Граница доступа к показателям macOS. Реализация появится в блоке диагностики,
/// а протокол уже позволяет тестировать слой представления на детерминированных данных.
public protocol SystemInformationProviding: Sendable {
    func systemInfo() async throws -> SystemInfo
    func systemMetrics() async throws -> SystemMetrics
}

public protocol SystemDiagnosing: Sendable {
    func runDiagnostics() async throws -> DiagnosticReport
}

public protocol StorageAnalyzing: Sendable {
    func storageOverview() async throws -> StorageOverview
    func scanDirectory(at url: URL, minimumSizeBytes: UInt64) async throws -> [StorageItem]
}

public protocol AIProviding: Sendable {
    func availableModels(for profile: AIProviderProfile) async throws -> [AIModel]
    func send(messages: [ChatMessage], using profile: AIProviderProfile, modelID: String) async throws -> ChatMessage
}

public protocol AIStreamingProviding: AIProviding {
    func stream(messages: [ChatMessage], using profile: AIProviderProfile, modelID: String) -> AsyncThrowingStream<String, Error>
}

public protocol AIProfileManaging: Sendable {
    func profiles() async -> [AIProviderProfile]
    func save(profile: AIProviderProfile, apiKey: String?) async throws
    func delete(profileID: UUID) async throws
}

public protocol AgentBridging: Sendable {
    func availableCommands() async -> [AgentCommand]
    func execute(command: AgentCommandRequest) async throws -> AgentCommandResult
    func activeTasks() async -> [AgentTask]
    func cancelTask(id: UUID) async
}

/// Локальная интеграция клиентов MCP. Она не выдаёт агенту доступ к shell:
/// запускаются только фиксированные операции регистрации собственного исполнителя.
public protocol MCPConnectionManaging: Sendable {
    func status(for client: MCPClient) async -> MCPConnectionStatus
    func connect(_ client: MCPClient) async throws -> MCPConnectionStatus
    /// Удаляет только запись Athena из конфигурации выбранного клиента.
    /// Другие MCP-серверы и настройки пользователя остаются без изменений.
    func disconnect(_ client: MCPClient) async throws -> MCPConnectionStatus
    func previewCodexConnection(connected: Bool) async throws -> CodexConnectionPlan
    func applyCodexConnection(_ plan: CodexConnectionPlan) async throws -> MCPConnectionStatus
    func previewHarnessConnection(connected: Bool) async throws -> HarnessConnectionPlan
    func applyHarnessConnection(_ plan: HarnessConnectionPlan) async throws -> MCPConnectionStatus
}

public extension MCPConnectionManaging {
    /// Недоступный либо тестовый backend не получает неявное право регистрации.
    func previewCodexConnection(connected: Bool) async throws -> CodexConnectionPlan { throw ServiceError.unavailableFeature(.codexSubagent) }
    func applyCodexConnection(_ plan: CodexConnectionPlan) async throws -> MCPConnectionStatus { throw ServiceError.unavailableFeature(.codexSubagent) }
    func previewHarnessConnection(connected: Bool) async throws -> HarnessConnectionPlan { throw ServiceError.unavailableFeature(.harnessSubagent) }
    func applyHarnessConnection(_ plan: HarnessConnectionPlan) async throws -> MCPConnectionStatus { throw ServiceError.unavailableFeature(.harnessSubagent) }
}

/// Конечные коды встроенных причин отделены от произвольных строк интеграции.
/// Это Swift API, не новая схема JSON: legacy callers по-прежнему могут передать
/// String, который будет показан буквально, без поиска совпадений в каталоге.
public enum ServiceFeature: String, CaseIterable, Sendable {
    case systemInformation
    case systemMetrics
    case diagnostics
    case storageAnalysis
    case storageScan
    case aiProviders
    case aiChat
    case agentBridge
    case mcpConnection
    case codexSubagent
    case harnessSubagent
    case athenaMCPExecutable
    case localConsent

    public var originalTitle: String {
        switch self {
        case .systemInformation: "Системная информация"
        case .systemMetrics: "Системные показатели"
        case .diagnostics: "Диагностика"
        case .storageAnalysis: "Анализ накопителя"
        case .storageScan: "Сканирование накопителя"
        case .aiProviders: "ИИ-провайдеры"
        case .aiChat: "ИИ-чат"
        case .agentBridge: "Agent Bridge"
        case .mcpConnection: "Подключение MCP"
        case .codexSubagent: "Подключение субагента Codex"
        case .harnessSubagent: "Подключение субагента Harness"
        case .athenaMCPExecutable: "MCP-исполнитель Athena"
        case .localConsent: "Команда требует локального согласия"
        }
    }
}

public enum ServiceInputReason: String, CaseIterable, Sendable {
    case commandNotAllowed
    case unknownCommand

    public var originalDescription: String {
        switch self {
        case .commandNotAllowed: "Команда внешнего агента не входит в разрешённый список."
        case .unknownCommand: "Неизвестная команда."
        }
    }
}

public enum ServiceError: LocalizedError, Equatable, Sendable {
    case unavailable(feature: String)
    case invalidInput(reason: String)
    case unavailableFeature(ServiceFeature)
    case invalidOperation(ServiceInputReason)

    public var errorDescription: String? {
        switch self {
        case let .unavailableFeature(feature):
            return "Функция «\(feature.originalTitle)» пока недоступна."
        case let .invalidOperation(reason):
            return "Некорректные входные данные: \(reason.originalDescription)"
        case let .unavailable(feature):
            return "Функция «\(feature)» пока недоступна."
        case let .invalidInput(reason):
            return "Некорректные входные данные: \(reason)"
        }
    }
}

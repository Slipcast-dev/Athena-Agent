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
    func previewCodexConnection(connected: Bool) async throws -> CodexConnectionPlan { throw ServiceError.unavailable(feature: "Подключение субагента Codex") }
    func applyCodexConnection(_ plan: CodexConnectionPlan) async throws -> MCPConnectionStatus { throw ServiceError.unavailable(feature: "Подключение субагента Codex") }
    func previewHarnessConnection(connected: Bool) async throws -> HarnessConnectionPlan { throw ServiceError.unavailable(feature: "Подключение субагента Harness") }
    func applyHarnessConnection(_ plan: HarnessConnectionPlan) async throws -> MCPConnectionStatus { throw ServiceError.unavailable(feature: "Подключение субагента Harness") }
}

public enum ServiceError: LocalizedError, Equatable, Sendable {
    case unavailable(feature: String)
    case invalidInput(reason: String)

    public var errorDescription: String? {
        switch self {
        case let .unavailable(feature):
            return "Функция «\(feature)» пока недоступна."
        case let .invalidInput(reason):
            return "Некорректные входные данные: \(reason)"
        }
    }
}

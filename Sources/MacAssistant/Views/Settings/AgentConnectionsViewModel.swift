import Foundation
import MacAssistantCore
import EcosystemClientAdapters

/// Изменение конфигураций остаётся в проверенных сервисах MCP, а не в форме.
@MainActor
final class AgentConnectionsViewModel: ObservableObject {
    @Published private(set) var commands: [AgentCommand] = []
    @Published private(set) var statuses: [MCPClient: MCPConnectionStatus] = [:]
    @Published private(set) var isUpdatingConnection = false
    @Published var error: String?

    private let agentBridge: any AgentBridging
    private let connections: any MCPConnectionManaging
    private var revision = 0

    init(agentBridge: any AgentBridging, connections: any MCPConnectionManaging) {
        self.agentBridge = agentBridge
        self.connections = connections
    }

    func load() async {
        // Не запускаем повторный опрос из этого экрана во время изменения записи.
        guard !isUpdatingConnection else { return }
        let snapshot = revision
        commands = await agentBridge.availableCommands()
        for client in MCPClient.allCases {
            let status = await connections.status(for: client)
            // Старый опрос не перезаписывает результат подключения, даже если
            // операция успела завершиться, пока сервис возвращал статус.
            if revision == snapshot { statuses[client] = status }
        }
    }

    func connect(_ client: MCPClient) async {
        guard !isUpdatingConnection else { return }
        revision += 1
        isUpdatingConnection = true
        error = nil
        defer { isUpdatingConnection = false }
        do {
            statuses[client] = try await connections.connect(client)
        } catch {
            self.error = error.localizedDescription
            statuses[client] = await connections.status(for: client)
        }
    }

    func disconnect(_ client: MCPClient) async {
        guard !isUpdatingConnection else { return }
        revision += 1
        isUpdatingConnection = true
        error = nil
        defer { isUpdatingConnection = false }
        do {
            statuses[client] = try await connections.disconnect(client)
        } catch {
            self.error = error.localizedDescription
            statuses[client] = await connections.status(for: client)
        }
    }

    @Published var codexPlan: CodexConnectionPlan?

    func prepareCodexConnection(connected: Bool) async {
        guard !isUpdatingConnection else { return }
        isUpdatingConnection = true; error = nil
        defer { isUpdatingConnection = false }
        do { codexPlan = try await connections.previewCodexConnection(connected: connected) }
        catch { self.error = error.localizedDescription }
    }

    func applyCodexPlan(_ plan: CodexConnectionPlan) async {
        guard !isUpdatingConnection else { return }
        codexPlan = nil; isUpdatingConnection = true; error = nil
        revision += 1; defer { isUpdatingConnection = false }
        do { statuses[.codex] = try await connections.applyCodexConnection(plan) }
        catch { self.error = error.localizedDescription; statuses[.codex] = await connections.status(for: .codex) }
    }

    @Published var harnessPlan: HarnessConnectionPlan?

    func prepareHarnessConnection(connected: Bool) async {
        guard !isUpdatingConnection else { return }
        isUpdatingConnection = true; error = nil
        defer { isUpdatingConnection = false }
        do { harnessPlan = try await connections.previewHarnessConnection(connected: connected) }
        catch { self.error = error.localizedDescription }
    }

    /// Системный диалог закрывает presentation-state до async-записи: принимаем
    /// захваченный план аргументом, как и при подключении Codex.
    func applyHarnessPlan(_ plan: HarnessConnectionPlan) async {
        guard !isUpdatingConnection else { return }
        harnessPlan = nil; isUpdatingConnection = true; error = nil
        revision += 1; defer { isUpdatingConnection = false }
        do { statuses[.deepSeekHarness] = try await connections.applyHarnessConnection(plan) }
        catch { self.error = error.localizedDescription; statuses[.deepSeekHarness] = await connections.status(for: .deepSeekHarness) }
    }

    func status(for client: MCPClient) -> MCPConnectionStatus {
        statuses[client] ?? .notConfigured
    }
}

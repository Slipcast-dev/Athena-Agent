import SwiftUI
import MacAssistantCore

/// Подтверждения остаются обязательными при изменении внешних конфигураций.
struct AgentConnectionSettings: View {
    @ObservedObject var viewModel: AgentConnectionsViewModel

    var body: some View {
        Section(SettingsBlock.connections.rawValue) {
            Text("Подключите Codex или DeepSeek Harness, чтобы обращаться к функциям Athena из привычного чата.")
                .font(.callout).foregroundStyle(.secondary)
            ForEach(MCPClient.allCases) { client in
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(client.title)
                        Text(statusTitle(viewModel.status(for: client)))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 12)
                    connectionControl(for: client)
                }
            }
            if viewModel.isUpdatingConnection { ProgressView("Обновление подключения…") }
            Button("Обновить статусы", systemImage: "arrow.clockwise") {
                Task { await viewModel.load() }
            }
            .disabled(viewModel.isUpdatingConnection)
            Text("Статус показывает наличие настройки MCP, а не активное соединение. После подключения или отключения перезапустите соответствующий клиент.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .confirmationDialog("Подключение субагента Harness", isPresented: Binding(
            get: { viewModel.harnessPlan != nil }, set: { if !$0 { viewModel.harnessPlan = nil } }
        ), titleVisibility: .visible) {
            if let plan = viewModel.harnessPlan {
                Button(plan.connected ? "Подключить Athena" : "Отключить Athena") {
                    Task { await viewModel.applyHarnessPlan(plan) }
                }
            }
            Button("Отмена", role: .cancel) { viewModel.harnessPlan = nil }
        } message: {
            Text((viewModel.harnessPlan?.changes ?? []).joined(separator: "\n") + "\nМодель и провайдер наследуются из настроек Harness.")
        }
        .confirmationDialog("Подключение субагента Codex", isPresented: Binding(
            get: { viewModel.codexPlan != nil }, set: { if !$0 { viewModel.codexPlan = nil } }
        ), titleVisibility: .visible) {
            if let plan = viewModel.codexPlan {
                Button(plan.connected ? "Подключить Athena" : "Отключить Athena") {
                    Task { await viewModel.applyCodexPlan(plan) }
                }
            }
            Button("Отмена", role: .cancel) { viewModel.codexPlan = nil }
        } message: {
            Text((viewModel.codexPlan?.changes ?? []).joined(separator: "\n") + "\nМодель и провайдер наследуются из настроек Codex.")
        }
        .alert("Не удалось изменить подключение", isPresented: Binding(
            get: { viewModel.error != nil }, set: { if !$0 { viewModel.error = nil } }
        )) {
            Button("OK", role: .cancel) { viewModel.error = nil }
        } message: { Text(viewModel.error ?? "") }
    }

    /// Настроенный MCP не является доказательством handshake внешнего клиента.
    private func statusTitle(_ status: MCPConnectionStatus) -> String {
        switch status {
        case .configured: "Настроено"
        case .notConfigured: "Не подключено"
        case let .unavailable(reason): reason
        }
    }

    @ViewBuilder
    private func connectionControl(for client: MCPClient) -> some View {
        if viewModel.status(for: client) == .configured {
            Button("Отключить", role: .destructive) {
                if client == .codex { Task { await viewModel.prepareCodexConnection(connected: false) } }
                else { Task { await viewModel.prepareHarnessConnection(connected: false) } }
            }
                .disabled(viewModel.isUpdatingConnection)
                .accessibilityLabel("Отключить \(client.title)")
        } else {
            Button("Подключить") {
                if client == .codex { Task { await viewModel.prepareCodexConnection(connected: true) } }
                else { Task { await viewModel.prepareHarnessConnection(connected: true) } }
            }
                .disabled(viewModel.isUpdatingConnection)
                .accessibilityLabel("Подключить \(client.title)")
        }
    }
}

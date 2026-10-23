import SwiftUI
import EcosystemUI
import EcosystemLocalization
import MacAssistantCore

/// Подтверждения остаются обязательными при изменении внешних конфигураций.
struct AgentConnectionSettings: View {
    @ObservedObject var viewModel: AgentConnectionsViewModel

    @Environment(\.agentLanguage) private var agentLanguage
    private var l10n: AthenaLocalization { AthenaLocalization(language: agentLanguage) }

    // Захватываем язык до async preview: смена настройки во время ожидания
    // не меняет формулировку уже начатого подтверждения внешней записи.
    @State private var codexLanguage = ConfirmationLanguage(language: .russian)
    @State private var harnessLanguage = ConfirmationLanguage(language: .russian)
    private var codexL10n: AthenaLocalization { AthenaLocalization(language: codexLanguage.language) }
    private var harnessL10n: AthenaLocalization { AthenaLocalization(language: harnessLanguage.language) }

    var body: some View {
        Section(l10n.text(SettingsBlock.connections.rawValue)) {
            Text(l10n.text("Подключите Codex или DeepSeek Harness, чтобы обращаться к функциям Athena из привычного чата."))
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
            Text(l10n.text("Описания изменений и сообщения внешних служб показаны на исходном языке."))
                .font(.caption).foregroundStyle(.secondary)
            PlannedHermesConnection()
            if viewModel.isUpdatingConnection { ProgressView(l10n.text("Обновление подключения…")) }
            Button(l10n.text("Обновить статусы"), systemImage: "arrow.clockwise") {
                Task { await viewModel.load() }
            }
            .disabled(viewModel.isUpdatingConnection)
            Text(l10n.text("Статус показывает наличие настройки MCP, а не активное соединение. После подключения или отключения перезапустите соответствующий клиент."))
                .font(.caption).foregroundStyle(.secondary)
        }
        .confirmationDialog(harnessL10n.text("Подключение субагента Harness"), isPresented: Binding(
            get: { viewModel.harnessPlan != nil }, set: { if !$0 { viewModel.harnessPlan = nil } }
        ), titleVisibility: .visible) {
            if let plan = viewModel.harnessPlan {
                Button(plan.connected ? harnessL10n.text("Подключить Athena") : harnessL10n.text("Отключить Athena")) {
                    Task { await viewModel.applyHarnessPlan(plan) }
                }
            }
            Button(harnessL10n.text("Отмена"), role: .cancel) { viewModel.harnessPlan = nil }
        } message: {
            Text((viewModel.harnessPlan?.changes ?? []).joined(separator: "\n") + "\n" + harnessL10n.text("Модель и провайдер наследуются из настроек Harness.") + "\n" + harnessL10n.text("Описания изменений и сообщения внешних служб показаны на исходном языке."))
        }
        .confirmationDialog(codexL10n.text("Подключение субагента Codex"), isPresented: Binding(
            get: { viewModel.codexPlan != nil }, set: { if !$0 { viewModel.codexPlan = nil } }
        ), titleVisibility: .visible) {
            if let plan = viewModel.codexPlan {
                Button(plan.connected ? codexL10n.text("Подключить Athena") : codexL10n.text("Отключить Athena")) {
                    Task { await viewModel.applyCodexPlan(plan) }
                }
            }
            Button(codexL10n.text("Отмена"), role: .cancel) { viewModel.codexPlan = nil }
        } message: {
            Text((viewModel.codexPlan?.changes ?? []).joined(separator: "\n") + "\n" + codexL10n.text("Модель и провайдер наследуются из настроек Codex.") + "\n" + codexL10n.text("Описания изменений и сообщения внешних служб показаны на исходном языке."))
        }
        .alert(l10n.text("Не удалось изменить подключение"), isPresented: Binding(
            get: { viewModel.error != nil }, set: { if !$0 { viewModel.error = nil } }
        )) {
            Button("OK", role: .cancel) { viewModel.error = nil }
        } message: { Text(viewModel.error.map { l10n.render($0) } ?? "") }
    }

    /// Настроенный MCP не является доказательством handshake внешнего клиента.
    private func statusTitle(_ status: MCPConnectionStatus) -> String {
        switch status {
        case .configured: l10n.text("Настроено")
        case .notConfigured: l10n.text("Не подключено")
        case let .unavailable(reason): reason
        }
    }

    @ViewBuilder
    private func connectionControl(for client: MCPClient) -> some View {
        if viewModel.status(for: client) == .configured {
            Button(l10n.text("Отключить"), role: .destructive) {
                if client == .codex {
                    codexLanguage = ConfirmationLanguage(language: agentLanguage)
                    Task { await viewModel.prepareCodexConnection(connected: false) }
                } else {
                    harnessLanguage = ConfirmationLanguage(language: agentLanguage)
                    Task { await viewModel.prepareHarnessConnection(connected: false) }
                }
            }
                .disabled(viewModel.isUpdatingConnection)
                .accessibilityLabel(l10n.format("Отключить %@", client.title))
        } else {
            Button(l10n.text("Подключить")) {
                if client == .codex {
                    codexLanguage = ConfirmationLanguage(language: agentLanguage)
                    Task { await viewModel.prepareCodexConnection(connected: true) }
                } else {
                    harnessLanguage = ConfirmationLanguage(language: agentLanguage)
                    Task { await viewModel.prepareHarnessConnection(connected: true) }
                }
            }
                .disabled(viewModel.isUpdatingConnection)
                .accessibilityLabel(l10n.format("Подключить %@", client.title))
        }
    }
}

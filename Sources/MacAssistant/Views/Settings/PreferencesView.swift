import SwiftUI
import MacAssistantCore
import EcosystemLocalIPC
import EcosystemUI

/// Единая группировка для основного окна и системной сцены настроек.
enum SettingsBlock: String, CaseIterable {
    case appearance = "Оформление"
    case connections = "Подключения"
    case privacy = "Доступ и безопасность"
    case about = "О приложении"
}

struct PreferencesView: View {
    private let runtimeClient: Result<LocalRPCClient, Error>?
    @AppStorage("appearanceMode") private var appearanceMode = AppAppearance.system.rawValue
    @StateObject private var connections: AgentConnectionsViewModel

    init(container: AppContainer) {
        runtimeClient = container.services.localRuntimeClient
        _connections = StateObject(wrappedValue: AgentConnectionsViewModel(
            agentBridge: container.services.agentBridge,
            connections: container.services.mcpConnections
        ))
    }

    /// Внедрение модели позволяет проверять макеты без реальных конфигураций.
    init(connections: AgentConnectionsViewModel) {
        runtimeClient = nil
        _connections = StateObject(wrappedValue: connections)
    }

    var body: some View {
        Form {
            Section(SettingsBlock.appearance.rawValue) {
                Picker("Тема", selection: $appearanceMode) {
                    ForEach(AppAppearance.allCases) { appearance in
                        Text(appearance.title).tag(appearance.rawValue)
                    }
                }
                Text("«Как в системе» автоматически следует теме macOS.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            if let runtimeClient { LocalOperationsSection(client: runtimeClient); LocalRecoverySection(client: runtimeClient); LocalAccessSection(client: runtimeClient); LocalAutomationSection(client: runtimeClient) }
            AgentConnectionSettings(viewModel: connections)

            Section(SettingsBlock.privacy.rawValue) {
                Label("Только чтение данных", systemImage: "lock.shield")
                Text("Внешние агенты могут получать сведения о Mac, системные показатели, диагностику и сводку накопителя. Изменение файлов и выполнение команд терминала недоступны.")
                    .font(.callout).foregroundStyle(.secondary)
                DisclosureGroup("Доступные операции") {
                    ForEach(connections.commands) { command in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(command.title)
                            Text(command.description)
                                .font(.caption).foregroundStyle(.secondary)
                            Text(command.id)
                                .font(.caption.monospaced()).foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 3)
                    }
                }
                Text("Athena не отправляет данные облачным ИИ-провайдерам. Если вы передаёте результат внешнему агенту, дальнейшая обработка зависит от настроек Codex или Harness.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section(SettingsBlock.about.rawValue) {
                LabeledContent("Приложение", value: "Athena")
                LabeledContent("Версия", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Локальная сборка")
                Text("Локальная диагностика Mac. Общайтесь с ИИ в Codex или DeepSeek Harness, подключённых к Athena.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .task { await connections.load() }
    }
}

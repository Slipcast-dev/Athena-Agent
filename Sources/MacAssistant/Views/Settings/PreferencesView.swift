import SwiftUI
import EcosystemLocalization
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
    @Environment(\.localLanguageModel) private var language
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

    @Environment(\.agentLanguage) private var agentLanguage
    private var l10n: AthenaLocalization { AthenaLocalization(language: agentLanguage) }

    var body: some View {
        Form {
            if let language { LocalLanguageSection(model: language) }
            Section(l10n.text(SettingsBlock.appearance.rawValue)) {
                Picker(l10n.text("Тема"), selection: $appearanceMode) {
                    ForEach(AppAppearance.allCases) { appearance in
                        Text(l10n.text(appearance.title)).tag(appearance.rawValue)
                    }
                }
                Text(l10n.text("«Как в системе» автоматически следует теме macOS."))
                    .font(.caption).foregroundStyle(.secondary)
            }

            if let runtimeClient { LocalOperationsSection(client: runtimeClient); LocalRecoverySection(client: runtimeClient); LocalAccessSection(client: runtimeClient); LocalAutomationSection(client: runtimeClient) }
            AgentConnectionSettings(viewModel: connections)

            Section(l10n.text(SettingsBlock.privacy.rawValue)) {
                Label(l10n.text("Только чтение данных"), systemImage: "lock.shield")
                Text(l10n.text("Внешние агенты могут получать сведения о Mac, системные показатели, диагностику и сводку накопителя. Изменение файлов и выполнение команд терминала недоступны."))
                    .font(.callout).foregroundStyle(.secondary)
                DisclosureGroup(l10n.text("Доступные операции")) {
                    ForEach(connections.commands) { command in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(commandTitle(command))
                            Text(commandDescription(command))
                                .font(.caption).foregroundStyle(.secondary)
                            Text(command.id)
                                .font(.caption.monospaced()).foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 3)
                    }
                }
                Text(l10n.text("Athena не отправляет данные облачным ИИ-провайдерам. Если вы передаёте результат внешнему агенту, дальнейшая обработка зависит от настроек Codex или Harness."))
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section(l10n.text(SettingsBlock.about.rawValue)) {
                LabeledContent(l10n.text("Приложение"), value: "Athena")
                LabeledContent(l10n.text("Версия"), value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? l10n.text("Локальная сборка"))
                Text(l10n.text("Локальная диагностика Mac. Общайтесь с ИИ в Codex или DeepSeek Harness, подключённых к Athena."))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .task { await connections.load() }
    }

    /// Перевод ограничен стабильными ID четырёх встроенных операций. Новые
    /// описания внешнего поставщика не становятся ключами словаря случайно.
    private func commandTitle(_ command: AgentCommand) -> String {
        switch command.id {
        case "system.get_info": l10n.text("Сведения о Mac")
        case "system.get_metrics": l10n.text("Показатели системы")
        case "diagnostics.run": l10n.text("Локальная диагностика")
        case "storage.get_overview": l10n.text("Сводка накопителя")
        default: command.title
        }
    }

    private func commandDescription(_ command: AgentCommand) -> String {
        switch command.id {
        case "system.get_info": l10n.text("Модель, версия macOS, архитектура и число ядер без серийного номера.")
        case "system.get_metrics": l10n.text("Текущие CPU, память и свободное место без истории процессов.")
        case "diagnostics.run": l10n.text("Структурированный отчёт и безопасные рекомендации, созданные локально.")
        case "storage.get_overview": l10n.text("Общий и доступный объём системного накопителя без путей и списка файлов.")
        default: command.description
        }
    }
}

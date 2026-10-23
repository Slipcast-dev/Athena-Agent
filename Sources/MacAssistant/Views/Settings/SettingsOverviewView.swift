import SwiftUI
import EcosystemLocalization
import EcosystemUI
import MacAssistantCore

/// Все действия доступны прямо в разделе, без дополнительной кнопки перехода.
struct SettingsOverviewView: View {
    let container: AppContainer

    @Environment(\.agentLanguage) private var agentLanguage
    private var l10n: AthenaLocalization { AthenaLocalization(language: agentLanguage) }

    var body: some View {
        PreferencesView(container: container)
            .navigationTitle(l10n.text("Настройки"))
    }
}

import SwiftUI
import MacAssistantCore

/// Все действия доступны прямо в разделе, без дополнительной кнопки перехода.
struct SettingsOverviewView: View {
    let container: AppContainer

    var body: some View {
        PreferencesView(container: container)
            .navigationTitle("Настройки")
    }
}

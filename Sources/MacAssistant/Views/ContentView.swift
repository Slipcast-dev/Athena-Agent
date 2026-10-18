import SwiftUI
import MacAssistantCore

/// Корневой экран владеет выбором раздела, поскольку он относится к конкретному
/// окну. Бизнес-операции остаются в последующих ViewModel и сервисах.
struct ContentView: View {
    let container: AppContainer
    @SceneStorage("selectedSection") private var storedSection = AppSection.dashboard.rawValue

    private var selection: Binding<AppSection?> {
        Binding(
            get: { AppSection.restored(from: storedSection) },
            set: { storedSection = ($0 ?? .dashboard).rawValue }
        )
    }

    var body: some View {
        NavigationSplitView {
            SidebarView(selection: selection)
                .navigationSplitViewColumnWidth(min: SidebarStyle.minimumWidth,
                                                ideal: SidebarStyle.idealWidth,
                                                max: SidebarStyle.maximumWidth)
        } detail: {
            DetailRouter(section: selection.wrappedValue ?? .dashboard, container: container)
        }
        .navigationSplitViewStyle(.balanced)
    }
}

private struct DetailRouter: View {
    let section: AppSection
    let container: AppContainer

    @ViewBuilder
    var body: some View {
        switch section {
        case .dashboard:
            DashboardView(container: container)
        case .diagnostics:
            DiagnosticsView(container: container)
        case .storage:
            StorageView(container: container)
        case .settings:
            SettingsOverviewView(container: container)
        }
    }
}

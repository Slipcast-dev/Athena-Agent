import SwiftUI
import MacAssistantCore

/// Корневой экран владеет выбором раздела, поскольку он относится к конкретному
/// окну. Бизнес-операции остаются в последующих ViewModel и сервисах.
struct ContentView: View {
    let container: AppContainer
    @SceneStorage("selectedSection") private var storedSection = AppSection.processor.rawValue

    private var selection: Binding<AppSection?> {
        Binding(
            get: { AppSection.restored(from: storedSection) },
            set: { storedSection = ($0 ?? .processor).rawValue }
        )
    }

    var body: some View {
        NavigationSplitView {
            SidebarView(selection: selection)
                .navigationSplitViewColumnWidth(min: SidebarStyle.minimumWidth,
                                                ideal: SidebarStyle.idealWidth,
                                                max: SidebarStyle.maximumWidth)
        } detail: {
            DetailRouter(section: selection.wrappedValue ?? .processor, container: container)
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
        case .processor:
            ProcessorView(container: container)
        case .network:
            NetworkView(container: container)
        case .disk:
            DiskView(container: container)
        case .memory:
            MemoryView(container: container)
        case .battery:
            BatteryView(container: container)
        case .diagnostics:
            DiagnosticsView(container: container)
        case .settings:
            SettingsOverviewView(container: container)
        }
    }
}

import SwiftUI
import EcosystemLocalIPC
import EcosystemLocalization
import EcosystemUI
import MacAssistantCore

@main
struct MacAssistantApp: App {
    @NSApplicationDelegateAdaptor(AthenaAppDelegate.self) private var appDelegate
    /// Контейнер создаётся один раз на жизненный цикл приложения: экраны в
    /// последующих блоках будут получать зависимости через него, а не создавать сервисы сами.
    private let container: AppContainer?
    @StateObject private var language: LocalLanguageModel
    private let startupError: RuntimeMessage?
    /// Значение хранится в UserDefaults через AppStorage и доступно до создания
    /// первого окна, поэтому выбранная пользователем тема применяется сразу.
    @AppStorage("appearanceMode") private var appearanceMode = AppAppearance.system.rawValue

    init() {
        if AthenaLocalization.runProbeIfRequested() { exit(0) }
        if LocalizationProbe.runIfRequested() { exit(0) }
        do {
            try InstalledRuntimeBootstrap.configureEnvironment(domain: "athena")
            let created = AppContainer.makeDefault()
            container = created
            _language = StateObject(wrappedValue: LocalLanguageModel(client: created.services.localRuntimeClient))
            startupError = nil
        } catch {
            container = nil
            _language = StateObject(wrappedValue: LocalLanguageModel(client: .failure(error)))
            startupError = .capture(error)
        }
    }

    private var preferredColorScheme: ColorScheme? {
        AppAppearance(rawValue: appearanceMode)?.colorScheme
    }

    var body: some Scene {
        WindowGroup("Athena") {
            Group {
                if let container {
                    ContentView(container: container)
                        .preferredColorScheme(preferredColorScheme)
                } else {
                    InstalledRuntimeFailureView(message: AgentLocalization(language: language.state.effectiveLanguage).runtimeMessage(startupError ?? RuntimeMessage("runtime.error.unknown")))
                }
            }.agentLanguageContext(language)
        }
        .defaultSize(width: 900, height: 620)

        // Оба входа используют один экран: набор подключений не должен
        // различаться в основном окне и при нажатии Cmd+,.
        Settings {
            Group {
                if let container {
                    PreferencesView(container: container)
                        .frame(width: 640, height: 650)
                        .preferredColorScheme(preferredColorScheme)
                } else {
                    InstalledRuntimeFailureView(message: AgentLocalization(language: language.state.effectiveLanguage).runtimeMessage(startupError ?? RuntimeMessage("runtime.error.unknown")))
                }
            }.agentLanguageContext(language)
        }
    }
}

/// Упакованная ICNS-иконка задаётся и для Dock. В режиме SwiftPM используем
/// исходный ресурс, поскольку самостоятельный бинарник не имеет Info.plist.
final class AthenaAppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        let iconURL = Bundle.main.url(forResource: "Athena", withExtension: "icns")
            ?? Bundle.module.url(forResource: "AgentAthena", withExtension: "png")
        if let iconURL, let icon = NSImage(contentsOf: iconURL) {
            NSApplication.shared.applicationIconImage = icon
        }
    }
}

/// В режиме `system` SwiftUI получает `nil` и наследует текущую тему macOS.
/// Другие варианты принудительно задают оформление только внутри приложения.
enum AppAppearance: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: "Как в системе"
        case .light: "Светлая"
        case .dark: "Тёмная"
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}

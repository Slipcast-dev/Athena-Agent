import SwiftUI
import EcosystemLocalIPC
import EcosystemUI
import MacAssistantCore

@main
struct MacAssistantApp: App {
    @NSApplicationDelegateAdaptor(AthenaAppDelegate.self) private var appDelegate
    /// Контейнер создаётся один раз на жизненный цикл приложения: экраны в
    /// последующих блоках будут получать зависимости через него, а не создавать сервисы сами.
    private let container: AppContainer?
    private let startupError: String?
    /// Значение хранится в UserDefaults через AppStorage и доступно до создания
    /// первого окна, поэтому выбранная пользователем тема применяется сразу.
    @AppStorage("appearanceMode") private var appearanceMode = AppAppearance.system.rawValue

    init() {
        do {
            try InstalledRuntimeBootstrap.configureEnvironment(domain: "athena")
            container = AppContainer.makeDefault()
            startupError = nil
        } catch {
            container = nil
            startupError = error.localizedDescription
        }
    }

    private var preferredColorScheme: ColorScheme? {
        AppAppearance(rawValue: appearanceMode)?.colorScheme
    }

    var body: some Scene {
        WindowGroup("Athena") {
            if let container {
                ContentView(container: container)
                    .preferredColorScheme(preferredColorScheme)
            } else {
                InstalledRuntimeFailureView(message: startupError ?? "Ошибка локального профиля.")
            }
        }
        .defaultSize(width: 900, height: 620)

        // Оба входа используют один экран: набор подключений не должен
        // различаться в основном окне и при нажатии Cmd+,.
        Settings {
            if let container {
                PreferencesView(container: container)
                    .frame(width: 640, height: 650)
                    .preferredColorScheme(preferredColorScheme)
            } else {
                InstalledRuntimeFailureView(message: startupError ?? "Ошибка локального профиля.")
            }
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

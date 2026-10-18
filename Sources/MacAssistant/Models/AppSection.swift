import Foundation

/// Стабильные идентификаторы разделов. Строковые значения используются только
/// для сохранения выбранного пункта в рамках окна через `SceneStorage`.
enum AppSection: String, CaseIterable, Identifiable {
    case dashboard
    case diagnostics
    case storage
    case settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .dashboard: "Обзор"
        case .diagnostics: "Диагностика"
        case .storage: "Накопитель"
        case .settings: "Настройки"
        }
    }

    var systemImage: String {
        switch self {
        case .dashboard: "square.grid.2x2"
        case .diagnostics: "stethoscope"
        case .storage: "internaldrive"
        case .settings: "gearshape"
        }
    }

    /// Сохранённые окна с удалёнными ИИ-экранами открывают обзор; настройки
    /// подключений из прежнего раздела «Агенты» переехали в настройки.
    static func restored(from rawValue: String) -> AppSection {
        if rawValue == "agents" { return .settings }
        return AppSection(rawValue: rawValue) ?? .dashboard
    }
}

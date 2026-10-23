import Foundation

/// Стабильные идентификаторы разделов. Строковые значения используются только
/// для сохранения выбранного пункта в рамках окна через `SceneStorage`.
enum AppSection: String, CaseIterable, Identifiable {
    case processor
    case network
    case disk
    case memory
    case battery
    case diagnostics
    case settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .processor: "Процессор"
        case .network: "Сеть"
        case .disk: "Диск"
        case .memory: "Память"
        case .battery: "Аккумулятор"
        case .diagnostics: "Диагностика"
        case .settings: "Настройки"
        }
    }

    var systemImage: String {
        switch self {
        case .processor: "cpu"
        case .network: "network"
        case .disk: "externaldrive"
        case .memory: "memorychip"
        case .battery: "battery.100percent"
        case .diagnostics: "stethoscope"
        case .settings: "gearshape"
        }
    }

    /// Сохраняем маршрут старых окон без переписывания пользовательских defaults.
    /// Удалённый обзор переходит в CPU, анализ диска — в новый раздел «Диск».
    static func restored(from rawValue: String) -> AppSection {
        switch rawValue {
        case "agents": .settings
        case "storage": .disk
        default: AppSection(rawValue: rawValue) ?? .processor
        }
    }
}

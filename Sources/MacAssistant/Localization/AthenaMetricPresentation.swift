import Foundation
import MacAssistantCore

/// Адаптер переводит признаки качества по enum, не изменяя raw metrics,
/// сроки freshness или backend-алгоритм. Отсутствие измерения не равно нулю.
enum AthenaMetricPresentation {
    static func stateTitle(_ state: MeasurementState, using l10n: AthenaLocalization) -> String {
        switch state {
        case .available: return l10n.text("Измерение доступно")
        case .warmingUp: return l10n.text("Накопление измерений")
        case .unavailable: return l10n.text("Измерение недоступно")
        case .unsupported: return l10n.text("Измерение не поддерживается")
        }
    }
    static func cpu(_ metrics: SystemMetrics, using l10n: AthenaLocalization) -> String {
        let quality = metrics.quality()
        guard quality.cpu == .available else { return stateTitle(quality.cpu, using: l10n) }
        guard let value = metrics.cpuUsagePercent else { return stateTitle(.unavailable, using: l10n) }
        return value.formatted(.number.precision(.fractionLength(1))) + " %"
    }
    static func freshness(_ metrics: SystemMetrics, now: Date, using l10n: AthenaLocalization) -> String {
        if metrics.quality(now: now).stale {
            return l10n.text("Показатели устарели. Обновите данные перед оценкой состояния.")
        }
        return l10n.format("Обновлено: %@", metrics.capturedAt.formatted(date: .abbreviated, time: .shortened))
    }
}

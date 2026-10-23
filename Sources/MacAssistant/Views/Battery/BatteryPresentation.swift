import Foundation
import EcosystemLocalization
import MacAssistantCore

struct BatteryChartPoint: Identifiable {
    let id: Int
    let date: Date
    let percent: Double
    let segment: Int
    /// Пропуски/обратный ход часов разрывают линию. При шаге 15 с разрыв
    /// больше двух интервалов также не изображается непрерывным измерением.
    static func make(_ history: [MonitoringHistoryPoint]) -> [BatteryChartPoint] {
        var result: [BatteryChartPoint] = [], segment = 0
        var previous: Date?
        for (index, row) in history.enumerated() {
            guard row.state == .available, let charge = row.values["charge"], charge.isFinite, (0...100).contains(charge) else {
                segment += 1; previous = nil; continue
            }
            if let previous, row.capturedAt <= previous || row.capturedAt.timeIntervalSince(previous) > 30 { segment += 1 }
            result.append(.init(id: index, date: row.capturedAt, percent: charge, segment: segment))
            previous = row.capturedAt
        }
        return result
    }
}

enum BatteryFormat {
    static func number(_ value: Double?, language: AgentLanguage, suffix: String = "") -> String {
        guard let value, value.isFinite else { return "—" }
        return value.formatted(.number.locale(Locale(identifier: language.rawValue)).precision(.fractionLength(0...2))) + suffix
    }
    static func minutes(_ field: MonitoringMetric<Int>?, using l10n: AthenaLocalization) -> String {
        if field?.state == .warmingUp { return l10n.text("Время рассчитывается") }
        guard let value = field?.value else { return "—" }
        return l10n.format("%@ мин", String(value))
    }
}

import Charts
import SwiftUI
import EcosystemLocalization
import MacAssistantCore

/// История RAM канала батареи ограничена 15 минутами общим координатором.
/// Hover и выбор позволяют прочитать точку, цвет дополняется числом и подписью.
struct BatteryChart: View {
    @Environment(\.agentLanguage) private var language
    @State private var inspection: Date?
    let points: [BatteryChartPoint]
    let history: [MonitoringHistoryPoint]
    let window: ProcessorHistoryWindow
    private var l10n: AthenaLocalization { .init(language: language) }
    private var end: Date { history.last?.capturedAt ?? Date() }
    private var selected: BatteryChartPoint? {
        guard let inspection else { return nil }
        return points.min { abs($0.date.timeIntervalSince(inspection)) < abs($1.date.timeIntervalSince(inspection)) }
    }
    var body: some View {
        VStack(alignment: .leading) {
            Chart {
                ForEach(points) { point in
                    LineMark(x: .value(l10n.text("Время"), point.date), y: .value(l10n.text("Заряд, %"), point.percent), series: .value("segment", point.segment))
                        .foregroundStyle(.green).lineStyle(StrokeStyle(lineWidth: 2))
                    PointMark(x: .value(l10n.text("Время"), point.date), y: .value(l10n.text("Заряд, %"), point.percent)).foregroundStyle(.green)
                }
                if let selected { RuleMark(x: .value(l10n.text("Время"), selected.date)).foregroundStyle(.secondary) }
            }
            .chartYScale(domain: 0.0...100.0)
            .chartXScale(domain: end.addingTimeInterval(-Double(window.rawValue))...end)
            .chartYAxis { AxisMarks(values: [0, 25, 50, 75, 100]) }
            .chartXAxis { AxisMarks(values: .automatic(desiredCount: 4)) { _ in
                AxisGridLine(); AxisValueLabel(format: .dateTime.hour().minute().second())
            } }
            .chartYAxisLabel(l10n.text("Заряд, %"))
            .chartXSelection(value: $inspection)
            .chartOverlay { proxy in
                GeometryReader { geometry in
                    Color.clear.contentShape(Rectangle()).onContinuousHover { phase in
                        switch phase {
                        case .active(let location):
                            if let frame = proxy.plotFrame {
                                let bounds = geometry[frame]
                                inspection = bounds.contains(location) ? proxy.value(atX: location.x - bounds.minX, as: Date.self) : nil
                            }
                        case .ended: inspection = nil
                        }
                    }
                }
            }
            .frame(height: 220)
            .overlay { if points.isEmpty { Text(l10n.text("Ожидание измерений для графика")).foregroundStyle(.secondary) } }
            .accessibilityLabel(l10n.text("График заряда аккумулятора"))
            .accessibilityValue(BatteryFormat.number((selected ?? points.last)?.percent, language: language, suffix: "%"))
            if let selected {
                Text(selected.date.formatted(date: .omitted, time: .standard) + " · " + BatteryFormat.number(selected.percent, language: language, suffix: "%"))
                    .font(.caption).monospacedDigit()
            } else { Text(l10n.text("Наведите указатель на график, чтобы увидеть значение.")).font(.caption).foregroundStyle(.secondary) }
        }.transaction { $0.animation = nil }
    }
}

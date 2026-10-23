import Charts
import SwiftUI
import EcosystemLocalization
import MacAssistantCore

/// LineMark группируется по segment, а цвет/штрих — по семантическому ряду.
/// Благодаря этому разные отрезки после сбоя не соединяются через пустое время.
struct ProcessorChart: View {
    @Environment(\.agentLanguage) private var language
    @State private var inspection: Date?
    let points: [ProcessorChartPoint]
    let history: [MonitoringHistoryPoint]
    let window: ProcessorHistoryWindow
    let core: Int?
    private var l10n: AthenaLocalization { AthenaLocalization(language: language) }
    private var end: Date { history.last?.capturedAt ?? Date() }
    private var inspected: ProcessorChartPoint? {
        guard let inspection else { return nil }
        let series: ProcessorSeries = core == nil ? .total : .core
        return points.filter { $0.series == series }.min { abs($0.date.timeIntervalSince(inspection)) < abs($1.date.timeIntervalSince(inspection)) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Chart {
                ForEach(points) { point in
                    LineMark(x: .value(l10n.text("Время"), point.date), y: .value(l10n.text("Нагрузка, %"), point.value),
                             series: .value("segment", point.segment))
                        .foregroundStyle(color(point.series))
                        .lineStyle(stroke(point.series)).interpolationMethod(.linear)
                    if points.count <= 3 {
                        PointMark(x: .value(l10n.text("Время"), point.date), y: .value(l10n.text("Нагрузка, %"), point.value))
                            .foregroundStyle(color(point.series))
                    }
                }
                if let inspected {
                    RuleMark(x: .value(l10n.text("Время"), inspected.date)).foregroundStyle(.secondary)
                }
            }
            .chartYScale(domain: 0.0...100.0)
            .chartXScale(domain: end.addingTimeInterval(-Double(window.rawValue))...end)
            .chartYAxis { AxisMarks(values: [0, 25, 50, 75, 100]) }
            .chartXAxis { AxisMarks(values: .automatic(desiredCount: 4)) { _ in
                AxisGridLine(); AxisValueLabel(format: .dateTime.hour().minute().second())
            } }
            .chartYAxisLabel(l10n.text("Нагрузка, %"))
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
            .frame(height: ProcessorLayout.chartHeight)
            .overlay {
                if points.isEmpty {
                    Text(l10n.text("Ожидание измерений для графика"))
                        .font(.callout).foregroundStyle(.secondary).padding(12).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                }
            }
            .accessibilityLabel(core.map { l10n.format("График ядра %@", ($0 + 1).formatted()) } ?? l10n.text("График загрузки процессора"))
            .accessibilityValue(inspected.map { ProcessorFormat.percent($0.value) } ?? points.last(where: { $0.series == (core == nil ? .total : .core) }).map { ProcessorFormat.percent($0.value) } ?? l10n.text("Нет данных"))
            HStack(spacing: 16) {
                ForEach(core == nil ? [ProcessorSeries.total, .user, .system] : [.core], id: \.rawValue) { series in
                    HStack(spacing: 6) {
                        Path { $0.move(to: .zero); $0.addLine(to: CGPoint(x: 18, y: 0)) }
                            .stroke(color(series), style: stroke(series)).frame(width: 18, height: 2)
                        Text(l10n.text(series.title)).font(.caption)
                    }.accessibilityElement(children: .combine)
                }
            }
            if let inspected {
                Text(inspected.date.formatted(date: .omitted, time: .standard) + " · " + ProcessorFormat.percent(inspected.value))
                    .font(.caption).monospacedDigit().foregroundStyle(.secondary)
            } else {
                Text(l10n.text("Наведите указатель на график, чтобы увидеть значение."))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .transaction { $0.animation = nil }
    }

    private func color(_ series: ProcessorSeries) -> Color {
        switch series { case .total, .core: .blue; case .user: .purple; case .system: .primary }
    }
    private func stroke(_ series: ProcessorSeries) -> StrokeStyle {
        switch series {
        case .total, .core: StrokeStyle(lineWidth: 2)
        case .user: StrokeStyle(lineWidth: 2, dash: [5, 3])
        case .system: StrokeStyle(lineWidth: 2, dash: [2, 3])
        }
    }
}

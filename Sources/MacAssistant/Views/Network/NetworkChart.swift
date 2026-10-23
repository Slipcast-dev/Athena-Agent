import Charts
import SwiftUI
import EcosystemLocalization
import MacAssistantCore

/// Каждое направление имеет собственные разрывы: отсутствие TX не стирает RX.
/// Имя интерфейса используется как ключ только внутри числовой bounded history.
struct NetworkChartPoint: Identifiable {
    let id: String
    let date: Date
    let bytesPerSecond: Double
    let received: Bool
    let segment: String
    static func make(_ history: [MonitoringHistoryPoint], interface: String) -> [NetworkChartPoint] {
        guard !interface.isEmpty else { return [] }
        var output: [NetworkChartPoint] = []
        for received in [true, false] {
            let key = interface + (received ? ".received" : ".sent")
            var segment = 0
            var previous: Date?
            for (index, row) in history.enumerated() {
                guard row.state == .available, let value = row.values[key], value.isFinite, value >= 0 else {
                    segment += 1; previous = nil; continue
                }
                if let previous, row.capturedAt <= previous { segment += 1 }
                previous = row.capturedAt
                output.append(NetworkChartPoint(id: "\(key).\(index)", date: row.capturedAt,
                    bytesPerSecond: value, received: received, segment: "\(key).\(segment)"))
            }
        }
        return output
    }
}

struct NetworkChart: View {
    @Environment(\.agentLanguage) private var language
    @ObservedObject var model: NetworkViewModel
    @State private var inspection: Date?
    private var l10n: AthenaLocalization { AthenaLocalization(language: language) }
    private var end: Date { model.history.last?.capturedAt ?? Date() }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Chart(model.chartPoints) { point in
                LineMark(x: .value(l10n.text("Время"), point.date),
                         y: .value(l10n.text("МБ/с"), point.bytesPerSecond / 1_000_000), series: .value("segment", point.segment))
                    .foregroundStyle(by: .value(l10n.text("Направление"), point.received ? l10n.text("Приём") : l10n.text("Передача")))
                    .lineStyle(StrokeStyle(lineWidth: 2, dash: point.received ? [] : [6, 3])).interpolationMethod(.linear)
                    .accessibilityLabel(point.received ? l10n.text("Приём") : l10n.text("Передача"))
                    .accessibilityValue(NetworkFormat.rate(point.bytesPerSecond, language: language))
            }
            .chartForegroundStyleScale(domain: [l10n.text("Приём"), l10n.text("Передача")], range: [Color.blue, .purple])
            .chartYScale(domain: .automatic(includesZero: true))
            .chartXScale(domain: end.addingTimeInterval(-Double(model.historyWindow.rawValue))...end)
            .chartYAxisLabel(l10n.text("МБ/с"))
            .chartXSelection(value: $inspection)
            .chartOverlay { proxy in
                GeometryReader { geometry in
                    Color.clear.contentShape(Rectangle()).onContinuousHover { phase in
                        if case .active(let point) = phase, let frame = proxy.plotFrame {
                            let bounds = geometry[frame]
                            inspection = bounds.contains(point) ? proxy.value(atX: point.x - bounds.minX, as: Date.self) : nil
                        } else { inspection = nil }
                    }
                }
            }
            .frame(height: 220)
            .overlay { if model.chartPoints.isEmpty { Text(l10n.text("Ожидание измерений для графика")).foregroundStyle(.secondary) } }
            .accessibilityLabel(l10n.text("График сетевого трафика"))
            if let inspection, let point = model.history.min(by: { abs($0.capturedAt.timeIntervalSince(inspection)) < abs($1.capturedAt.timeIntervalSince(inspection)) }) {
                Text(point.capturedAt.formatted(date: .omitted, time: .standard) + " · " +
                     l10n.text("Приём") + ": " + NetworkFormat.rate(point.values[model.selectedInterface + ".received"], language: language) + " · " +
                     l10n.text("Передача") + ": " + NetworkFormat.rate(point.values[model.selectedInterface + ".sent"], language: language))
                    .font(.caption).monospacedDigit()
            }
        }
    }
}

enum NetworkFormat {
    static func bytes(_ value: UInt64?, language: AgentLanguage) -> String {
        guard let value, value <= UInt64(Int64.max) else { return "—" }
        return ByteCountFormatStyle(style: .decimal, spellsOutZero: false,
                                   locale: Locale(identifier: language.rawValue)).format(Int64(value))
    }

    static func rate(_ value: Double?, language: AgentLanguage) -> String {
        guard let value, value.isFinite, value >= 0, value < Double(Int64.max) else { return "—" }
        if value < 1000 {
            return value.formatted(.number.precision(.fractionLength(0...2)).locale(Locale(identifier: language.rawValue))) + " " +
                AthenaLocalization(language: language).text("Б/с")
        }
        let bytes = ByteCountFormatStyle(style: .decimal, spellsOutZero: false,
                                        locale: Locale(identifier: language.rawValue)).format(Int64(value))
        return bytes + AthenaLocalization(language: language).text("/с")
    }
}

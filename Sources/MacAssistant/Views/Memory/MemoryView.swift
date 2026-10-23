import SwiftUI
import Charts
import EcosystemLocalization
import MacAssistantCore

/// Та же модель видимости, что у CPU: видимое фоновое окно продолжает
/// мониторинг, закрытое/свёрнутое освобождает обе lease-группы.
struct MemoryView: View {
    @Environment(\.agentLanguage) private var language
    @StateObject private var model: MemoryViewModel
    @State private var visible = false
    @State private var paused = false
    init(container: AppContainer) {
        _model = StateObject(wrappedValue: MemoryViewModel(provider: container.services.liveMonitoring))
    }
    var body: some View {
        MemoryContent(model: model, paused: paused || !visible)
            .navigationTitle(AthenaLocalization(language: language).text("Память"))
            .toolbar {
                Button(AthenaLocalization(language: language).text(paused ? "Продолжить мониторинг" : "Приостановить мониторинг"),
                       systemImage: paused ? "play.fill" : "pause.fill") { paused.toggle() }
                    .keyboardShortcut("p", modifiers: [.command, .shift])
            }
            .background(DashboardWindowVisibility { visible = $0 })
            .task(id: visible && !paused) {
                guard visible && !paused else { return }
                await model.runWhileVisible()
            }
    }
}

struct MemoryContent: View {
    @Environment(\.agentLanguage) private var language
    @ObservedObject var model: MemoryViewModel
    var paused = false
    @State private var selectedDate: Date?
    private var l10n: AthenaLocalization { AthenaLocalization(language: language) }
    private var dimmed: Bool { paused || model.suspended || model.sample?.stale == true || model.runtimeError != nil }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                status
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 145), spacing: 16)], spacing: 16) {
                    card(l10n.text("Установлено ОЗУ"), model.metrics?.totalBytes.value)
                    card(l10n.text("Занято ОЗУ"), model.metrics?.usedBytes.value)
                    card(l10n.text("Доступно ОЗУ"), model.metrics?.availableBytes.value)
                    card(l10n.text("Wired-память"), model.metrics?.wiredBytes.value)
                    card(l10n.text("Сжатая память"), model.metrics?.compressedBytes.value)
                    card(l10n.text("Файловый кэш"), model.metrics?.cachedBytes.value)
                    card(l10n.text("Использовано swap"), model.metrics?.swapUsedBytes.value)
                    GroupBox { VStack(alignment: .leading, spacing: 8) {
                        Text(l10n.text("Давление памяти")).font(.callout).foregroundStyle(.secondary)
                        Label(pressureText, systemImage: pressureSymbol).font(.headline)
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(4) }
                        .accessibilityElement(children: .combine)
                }.opacity(dimmed ? 0.6 : 1)
                Text(l10n.text("Показатель «занято» — оценка. Кэш может быть освобождён macOS; категории памяти пересекаются."))
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                graph
                processes
            }.padding(20)
        }
    }
    private func format(_ value: UInt64?) -> String { MemoryFormat.bytes(value, language: language) }

    private func card(_ title: String, _ bytes: UInt64?) -> some View {
        GroupBox { VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.callout).foregroundStyle(.secondary)
            Text(format(bytes)).font(.title2.weight(.semibold)).monospacedDigit()
        }.frame(maxWidth: .infinity, alignment: .leading).padding(4) }.accessibilityElement(children: .combine)
    }
    private var status: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let error = model.runtimeError { Text(l10n.render(.runtime(error))) }
            else if model.suspended { Text(l10n.text("Мониторинг остановлен аварийной кнопкой. Возобновите его в настройках.")) }
            else if paused { Text(l10n.text("Обновление приостановлено")) }
            else if model.sample == nil { Text(l10n.text("Накопление измерений")) }
            else if model.sample?.stale == true { Text(l10n.text("Данные устарели. Ожидание свежего измерения.")) }
            else if let sample = model.sample, sample.state != .available { Text(AthenaMetricPresentation.stateTitle(sample.state, using: l10n)) }
            else { Text(l10n.text("ОЗУ: каждую секунду · процессы: каждые 5 секунд")) }
            if let sample = model.sample {
                Text(l10n.format("Обновлено: %@", sample.capturedAt.formatted(date: .omitted, time: .standard)))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }.accessibilityElement(children: .combine)
    }
    private var pressureText: String {
        switch model.metrics?.pressure.value {
        case .normal: l10n.text("Нормальное давление")
        case .warning: l10n.text("Повышенное давление")
        case .critical: l10n.text("Критическое давление")
        case nil: l10n.text("Нет данных")
        }
    }
    private var pressureSymbol: String {
        switch model.metrics?.pressure.value {
        case .normal: "checkmark.circle"
        case .warning: "exclamationmark.triangle"
        case .critical: "exclamationmark.octagon"
        case nil: "questionmark.circle"
        }
    }
    private var graph: some View {
        GroupBox(l10n.text("История памяти")) {
            VStack(alignment: .leading, spacing: 12) {
                Picker(l10n.text("Период графика"), selection: $model.historyWindow) {
                    Text(l10n.text("1 мин")).tag(ProcessorHistoryWindow.minute)
                    Text(l10n.text("5 мин")).tag(ProcessorHistoryWindow.fiveMinutes)
                    Text(l10n.text("15 мин")).tag(ProcessorHistoryWindow.fifteenMinutes)
                }.pickerStyle(.segmented).labelsHidden()
                    .accessibilityLabel(l10n.text("Период графика")).frame(maxWidth: 260)
                memoryChart
                if let selectedDate, let nearest = model.history.min(by: { abs($0.capturedAt.timeIntervalSince(selectedDate)) < abs($1.capturedAt.timeIntervalSince(selectedDate)) }) {
                    Text(nearest.capturedAt.formatted(date: .omitted, time: .standard) + " · " +
                         l10n.text("Занято ОЗУ") + ": " + format(nearest.values["used"].flatMap { $0 >= 0 && $0 < Double(UInt64.max) ? UInt64($0) : nil }))
                        .font(.caption).monospacedDigit()
                }
            }.padding(8)
        }
    }
    /// Небольшие выражения дают одинаковую типизацию на Swift из macOS CI
    /// и на новом локальном компиляторе; шкалы и оформление остаются прежними.
    private var chartUpperBound: Double {
        let installed = Double(model.metrics?.totalBytes.value ?? 0) / 1_073_741_824
        let observed = (model.chartPoints.map(\.bytes).max() ?? 0) / 1_073_741_824
        return max(1, installed, observed)
    }
    private var chartTimeRange: ClosedRange<Date> {
        let end = model.history.last?.capturedAt ?? Date()
        return end.addingTimeInterval(-Double(model.historyWindow.rawValue))...end
    }
    private func seriesStroke(_ key: String) -> StrokeStyle {
        let dash: [CGFloat]
        switch key {
        case "used": dash = []
        case "compressed": dash = [6, 3]
        default: dash = [2, 3]
        }
        return StrokeStyle(lineWidth: 2, dash: dash)
    }
    private func memoryLine(_ point: MemoryChartPoint) -> some ChartContent {
        let gibibytes: Double = point.bytes / 1_073_741_824
        return
                    LineMark(x: .value(l10n.text("Время"), point.date), y: .value(l10n.text("Память"), gibibytes),
                             series: .value("segment", point.segment))
                        .foregroundStyle(by: .value(l10n.text("График"), seriesTitle(point.key)))
                        .lineStyle(seriesStroke(point.key))
                        .interpolationMethod(.linear)
                        .accessibilityLabel(seriesTitle(point.key))
                        .accessibilityValue(format(point.bytes < Double(UInt64.max) ? UInt64(point.bytes) : nil))
    }
    private var memoryChart: some View {
                Chart(model.chartPoints) { point in
                    memoryLine(point)
                }
                .chartForegroundStyleScale(domain: [l10n.text("Занято ОЗУ"), l10n.text("Сжатая память"), l10n.text("Использовано swap")], range: [Color.blue, .purple, .primary])
                .chartYScale(domain: 0...chartUpperBound)
                .chartXScale(domain: chartTimeRange)
                .chartXAxisLabel(l10n.text("Время"))
                .chartYAxisLabel(l10n.text("ГиБ"))
                .chartXSelection(value: $selectedDate)
                .chartOverlay { proxy in
                    GeometryReader { geometry in
                        Rectangle().fill(.clear).contentShape(Rectangle()).onContinuousHover { phase in
                            if case .active(let location) = phase, let plot = proxy.plotFrame {
                                let x = location.x - geometry[plot].origin.x
                                selectedDate = x >= 0 && x <= geometry[plot].width ? proxy.value(atX: x) : nil
                            } else { selectedDate = nil }
                        }
                    }
                }
                .frame(height: 210).opacity(dimmed ? 0.6 : 1)
    }
    private func seriesTitle(_ key: String) -> String {
        switch key {
        case "used": l10n.text("Занято ОЗУ")
        case "compressed": l10n.text("Сжатая память")
        default: l10n.text("Использовано swap")
        }
    }
    private var processes: some View {
        GroupBox(l10n.text("Память приложений и процессов")) {
            VStack(alignment: .leading, spacing: 12) {
                ViewThatFits(in: .horizontal) {
                    HStack { modePicker; sortPicker }
                    VStack(alignment: .leading) { modePicker; sortPicker }
                }
                TextField(l10n.text("Поиск по имени или PID"), text: $model.search).textFieldStyle(.roundedBorder)
                if model.processSample?.stale == true || paused || model.suspended {
                    Text(l10n.text("Таблица процессов не обновляется")).font(.caption)
                }
                if model.processSample == nil || model.processSample?.state == .unavailable {
                    Text(l10n.text("Ожидание данных процессов")).font(.caption)
                }
                if let sample = model.processSample {
                    Text(l10n.format("Процессы обновлены: %@", sample.capturedAt.formatted(date: .omitted, time: .standard)))
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let summary = model.processSummary {
                    Text(l10n.format("Обнаружено: %@ · доступно: %@ · без данных: %@ · не показано: %@", summary.observed.formatted(), summary.readable.formatted(), summary.unavailable.formatted(), summary.omitted.formatted()))
                        .font(.caption).foregroundStyle(.secondary)
                    if !summary.enumerationComplete { Text(l10n.text("Список процессов может быть неполным")).font(.caption) }
                }
                Table(model.rows) {
                    TableColumn(l10n.text("Имя")) { row in
                        VStack(alignment: .leading) {
                            Text(row.name).lineLimit(1).help(row.name)
                            if let pid = row.pid { Text("PID \(pid)").font(.caption).foregroundStyle(.secondary) }
                            else { Text(l10n.format("Процессов: %@", row.members.formatted())).font(.caption).foregroundStyle(.secondary) }
                        }
                    }
                    TableColumn(l10n.text("Память")) { row in
                        Text((row.partial && row.bytes != nil ? "≥ " : "") + format(row.bytes)).monospacedDigit()
                            .help(row.partial ? l10n.text("Показана известная сумма; данные приложения могут быть неполными.") : l10n.text("Память процесса по данным macOS"))
                    }.width(min: 100, ideal: 140)
                }.frame(height: 300)
                    .opacity(paused || model.suspended || model.processSample?.stale == true || model.runtimeError != nil ? 0.6 : 1)
                    .overlay { if model.rows.isEmpty { Text(l10n.text("Нет подходящих процессов")) } }
                Text(l10n.text("Память приложений рассчитана по доступным процессам. Вспомогательные процессы объединены, если принадлежат тому же приложению. Сумма может отличаться от занятой ОЗУ. Показано не более 512 процессов."))
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }.padding(8)
        }
    }
    private var modePicker: some View {
        Picker(l10n.text("Группировка"), selection: $model.applications) {
            Text(l10n.text("Приложения")).tag(true)
            Text(l10n.text("Процессы")).tag(false)
        }.pickerStyle(.segmented)
    }
    private var sortPicker: some View {
        Picker(l10n.text("Сортировка"), selection: $model.sortByName) {
            Text(l10n.text("По памяти")).tag(false)
            Text(l10n.text("По имени")).tag(true)
        }.pickerStyle(.menu).fixedSize()
    }
}

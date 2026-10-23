import SwiftUI
import EcosystemLocalization
import MacAssistantCore

/// SwiftUI владеет состоянием окна. AppKit bridge сообщает только видимость;
/// уход фокуса в другое приложение НЕ останавливает видимый график CPU.
struct ProcessorView: View {
    @Environment(\.agentLanguage) private var language
    @StateObject private var model: ProcessorViewModel
    @State private var visible = false
    @State private var paused = false

    init(container: AppContainer) {
        _model = StateObject(wrappedValue: ProcessorViewModel(provider: container.services.liveMonitoring))
    }

    var body: some View {
        ProcessorContent(model: model, paused: paused || !visible)
            .navigationTitle(AthenaLocalization(language: language).text("Процессор"))
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

/// Единый набор отступов/размеров для native macOS карточек и обоих themes.
enum ProcessorLayout {
    static let spacing: CGFloat = 16
    static let inset: CGFloat = 20
    static let chartHeight: CGFloat = 220
    static let coreMinimumWidth: CGFloat = 130
}

struct ProcessorContent: View {
    @Environment(\.agentLanguage) private var language
    @ObservedObject var model: ProcessorViewModel
    var paused = false
    private var l10n: AthenaLocalization { AthenaLocalization(language: language) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: ProcessorLayout.spacing) {
                identity
                status
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 145), spacing: ProcessorLayout.spacing)], spacing: ProcessorLayout.spacing) {
                    ProcessorMetricCard(title: l10n.text("Общая нагрузка"), metric: model.metrics?.totalPercent)
                    ProcessorMetricCard(title: l10n.text("Пользователь"), metric: model.metrics?.userPercent)
                    ProcessorMetricCard(title: l10n.text("Система"), metric: model.metrics?.systemPercent)
                }.opacity(paused || model.sample?.stale == true || model.runtimeError != nil ? 0.6 : 1)
                graph
                cores
            }
            .padding(ProcessorLayout.inset)
        }
    }

    private var identity: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(model.metrics?.identity?.name ?? l10n.text("Процессор"))
                .font(.title2.weight(.semibold)).textSelection(.enabled)
            if let identity = model.metrics?.identity {
                Text(l10n.format("%@ физических / %@ логических", identity.physicalCoreCount.map(String.init) ?? "—",
                                 identity.logicalCoreCount.formatted())).foregroundStyle(.secondary)
                if let performance = identity.performanceCoreCount, let efficiency = identity.efficiencyCoreCount {
                    Text(l10n.format("%@ производительных · %@ энергоэффективных", performance.formatted(), efficiency.formatted()))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private var status: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(statusText, systemImage: statusSymbol).font(.callout)
            if let sample = model.sample {
                Text(l10n.format("Обновлено: %@", sample.capturedAt.formatted(date: .omitted, time: .standard)))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }.accessibilityElement(children: .combine)
    }
    private var statusText: String {
        if let error = model.runtimeError { return l10n.render(.runtime(error)) }
        if model.suspended { return l10n.text("Мониторинг остановлен аварийной кнопкой. Возобновите его в настройках.") }
        if paused { return l10n.text("Обновление приостановлено") }
        guard let sample = model.sample else { return l10n.text("Накопление измерений") }
        if sample.stale { return l10n.text("Данные устарели. Ожидание свежего измерения.") }
        if sample.state == .available { return l10n.text("Обновление каждую секунду") }
        return AthenaMetricPresentation.stateTitle(sample.state, using: l10n)
    }
    private var statusSymbol: String {
        if model.runtimeError != nil || model.suspended { return "exclamationmark.circle" }
        if paused { return "pause.circle" }
        return model.sample?.state == .available && model.sample?.stale == false ? "waveform.path" : "clock"
    }

    private var graph: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                ViewThatFits(in: .horizontal) {
                    HStack { graphPicker; Spacer(minLength: 16); windowPicker }
                    VStack(alignment: .leading, spacing: 12) { graphPicker; windowPicker }
                }
                ProcessorChart(points: model.chartPoints, history: model.history,
                               window: model.historyWindow, core: model.selectedCore)
            }.padding(8)
        }
    }
    private var graphPicker: some View {
        Picker(l10n.text("График"), selection: $model.selectedCore) {
            Text(l10n.text("Общая нагрузка")).tag(Int?.none)
            ForEach(0..<(model.metrics?.cores.count ?? 0), id: \.self) { index in
                Text(l10n.format("Ядро %@", (index + 1).formatted())).tag(Optional(index))
            }
        }.pickerStyle(.menu).fixedSize(horizontal: true, vertical: false)
    }
    private var windowPicker: some View {
        Picker(l10n.text("Период графика"), selection: $model.historyWindow) {
            ForEach(ProcessorHistoryWindow.allCases) { value in Text(l10n.text(value.title)).tag(value) }
        }.pickerStyle(.segmented).labelsHidden()
            .accessibilityLabel(l10n.text("Период графика")).frame(minWidth: 180, maxWidth: 230)
    }
    private var cores: some View {
        let fields = model.metrics?.cores ?? []
        return GroupBox(l10n.text("Загрузка по ядрам")) {
            VStack(alignment: .leading, spacing: 12) {
                Text(l10n.text("Индикаторы соответствуют логическим процессорам. Выберите ядро для графика."))
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: ProcessorLayout.coreMinimumWidth), spacing: 12)], spacing: 12) {
                    ForEach(Array(fields.enumerated()), id: \.offset) { index, metric in
                        ProcessorCoreButton(index: index, metric: metric,
                            selected: model.selectedCore == index) { model.selectedCore = index }
                    }
                }.opacity(paused || model.sample?.stale == true || model.runtimeError != nil ? 0.6 : 1)
            }.padding(8).frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct ProcessorMetricCard: View {
    @Environment(\.agentLanguage) private var language
    let title: String
    let metric: MonitoringMetric<Double>?
    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                Text(title).font(.callout).foregroundStyle(.secondary)
                Text(metric?.value.map(ProcessorFormat.percent) ?? "—").font(.system(size: 28, weight: .semibold)).monospacedDigit()
            }.frame(maxWidth: .infinity, alignment: .leading).padding(4)
        }.accessibilityElement(children: .combine)
    }
}

private struct ProcessorCoreButton: View {
    @Environment(\.agentLanguage) private var language
    let index: Int
    let metric: MonitoringMetric<Double>
    let selected: Bool
    let action: () -> Void
    private var l10n: AthenaLocalization { AthenaLocalization(language: language) }
    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(l10n.format("Ядро %@", (index + 1).formatted())).font(.callout.weight(.medium))
                    Spacer(minLength: 4)
                    Text(metric.value.map(ProcessorFormat.percent) ?? "—").font(.caption).monospacedDigit()
                }
                if let value = metric.value {
                    ProgressView(value: value, total: 100).tint(.accentColor).accessibilityHidden(true)
                } else {
                    RoundedRectangle(cornerRadius: 2).fill(.quaternary).frame(height: 4).accessibilityHidden(true)
                }
            }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
                .background(selected ? Color.accentColor.opacity(0.1) : Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(selected ? Color.accentColor : .clear, lineWidth: 2))
                .contentShape(Rectangle())
        }.buttonStyle(.plain)
            .accessibilityLabel(l10n.format("Ядро %@", (index + 1).formatted()))
            .accessibilityValue(metric.value.map(ProcessorFormat.percent) ?? AthenaMetricPresentation.stateTitle(metric.state, using: l10n))
            .accessibilityAddTraits(selected ? .isSelected : [])
            .help(l10n.text("Показать график этого ядра"))
    }
}

enum ProcessorFormat {
    static func percent(_ value: Double) -> String { value.formatted(.number.precision(.fractionLength(1))) + " %" }
}

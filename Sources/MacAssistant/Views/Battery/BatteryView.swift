import SwiftUI
import EcosystemLocalization
import MacAssistantCore

struct BatteryView: View {
    @Environment(\.agentLanguage) private var language
    @StateObject private var model: BatteryViewModel
    @State private var visible = false
    @State private var paused = false
    init(container: AppContainer) { _model = StateObject(wrappedValue: BatteryViewModel(provider: container.services.liveMonitoring)) }
    var body: some View {
        BatteryContent(model: model, paused: paused || !visible)
            .navigationTitle(AthenaLocalization(language: language).text("Аккумулятор"))
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

struct BatteryContent: View {
    @Environment(\.agentLanguage) private var language
    @ObservedObject var model: BatteryViewModel
    var paused = false
    private var l10n: AthenaLocalization { .init(language: language) }
    private var details: BatteryMonitoringDetails? { model.metrics?.details }
    private var dimmed: Bool { paused || model.suspended || model.runtimeError != nil || model.sample?.stale == true }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                status
                if model.metrics?.present.value == false {
                    ContentUnavailableView(l10n.text("Внутренний аккумулятор отсутствует"), systemImage: "powerplug",
                        description: Text(l10n.text("Это обычное состояние настольного Mac. Внешние ИБП здесь не отображаются.")))
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), spacing: 16)], spacing: 16) {
                        card(l10n.text("Заряд аккумулятора"), number(model.metrics?.chargePercent.value, "%"))
                        card(l10n.text("Источник питания"), powerSource)
                        card(l10n.text("Зарядка аккумулятора"), charging)
                        card(l10n.text("Циклы зарядки"), model.metrics?.cycleCount.value.map(String.init) ?? "—")
                        card(l10n.text("Состояние аккумулятора"), health)
                        card(l10n.text("Сервисное состояние"), condition)
                        card(l10n.text("Ёмкость относительно проектной"), number(details?.retainedCapacityPercent.value, "%"))
                        card(l10n.text("До разряда, оценка"), BatteryFormat.minutes(details?.minutesToEmpty, using: l10n))
                        card(l10n.text("До полной зарядки, оценка"), BatteryFormat.minutes(details?.minutesToFull, using: l10n))
                        card(l10n.text("Температура аккумулятора"), number(model.metrics?.temperatureCelsius.value, " °C"))
                        card(l10n.text("Напряжение аккумулятора"), number(details?.voltageVolts.value, l10n.text(" В")))
                        card(l10n.text("Ток аккумулятора"), number(details?.currentAmperes.value, l10n.text(" А")))
                        card(l10n.text("Мощность адаптера, номинальная"), number(details?.adapterWatts.value, l10n.text(" Вт")))
                    }.opacity(dimmed ? 0.6 : 1)
                    GroupBox(l10n.text("График заряда аккумулятора")) {
                        VStack(alignment: .leading, spacing: 12) {
                            Picker(l10n.text("Период графика"), selection: $model.historyWindow) {
                                Text(l10n.text("1 мин")).tag(ProcessorHistoryWindow.minute)
                                Text(l10n.text("5 мин")).tag(ProcessorHistoryWindow.fiveMinutes)
                                Text(l10n.text("15 мин")).tag(ProcessorHistoryWindow.fifteenMinutes)
                            }.pickerStyle(.segmented).frame(maxWidth: 360)
                            BatteryChart(points: model.chartPoints, history: model.history, window: model.historyWindow)
                        }.padding(8)
                    }.opacity(dimmed ? 0.6 : 1)
                    Text(l10n.text("Показатели обновляются каждые 15 секунд. История хранится в памяти до 15 минут во время мониторинга."))
                        .font(.caption).foregroundStyle(.secondary)
                    Text(l10n.text("«—» означает, что macOS не предоставила показатель или он сейчас неприменим. Время работы — оценка macOS; ток со знаком, мощность адаптера — номинальная."))
                        .font(.caption).foregroundStyle(.secondary)
                    Text(l10n.text("Процент ёмкости рассчитывается только по совместимым полям IOPS. Абсолютная ёмкость и температура из неподтверждённых полей драйвера не используются."))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }.padding(20)
        }
    }
    private var status: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let error = model.runtimeError { Text(l10n.render(.runtime(error))) }
            else if model.suspended { Text(l10n.text("Мониторинг остановлен аварийной кнопкой. Возобновите его в настройках.")) }
            else if paused { Text(l10n.text("Обновление приостановлено")) }
            else if model.sample?.stale == true { Text(l10n.text("Данные устарели. Ожидание свежего измерения.")) }
            else if let sample = model.sample, sample.state != .available { Text(AthenaMetricPresentation.stateTitle(sample.state, using: l10n)) }
            else if model.metrics?.present.state == .unsupported { Text(l10n.text("Несколько внутренних аккумуляторов: эта конфигурация пока не поддерживается.")) }
            else { Text(l10n.text("Мониторинг аккумулятора")) }
            if let date = model.sample?.capturedAt { Text(l10n.format("Обновлено: %@", date.formatted(date: .omitted, time: .standard))).font(.caption).foregroundStyle(.secondary) }
        }.accessibilityElement(children: .combine)
    }
    private func number(_ value: Double?, _ suffix: String) -> String { BatteryFormat.number(value, language: language, suffix: suffix) }
    private func card(_ title: String, _ value: String) -> some View {
        GroupBox { VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.callout).foregroundStyle(.secondary)
            Text(value).font(.title3.weight(.semibold)).monospacedDigit().textSelection(.enabled)
        }.padding(4).frame(maxWidth: .infinity, alignment: .leading) }.accessibilityElement(children: .combine)
    }
    private var powerSource: String {
        switch details?.powerSource.value {
        case .battery: l10n.text("От аккумулятора")
        case .external: l10n.text("Внешнее питание")
        case .offline: l10n.text("Источник отключён")
        case nil: "—"
        }
    }
    private var charging: String {
        if details?.fullyCharged.value == true { return l10n.text("Полностью заряжен") }
        switch model.metrics?.charging.value {
        case .some(true): return l10n.text("Заряжается")
        case .some(false): return l10n.text("Не заряжается")
        case nil: return "—"
        }
    }
    private var health: String {
        switch details?.health.value {
        case .good: l10n.text("Хорошее")
        case .fair: l10n.text("Ограниченная ёмкость")
        case .poor: l10n.text("Не обеспечивает питание")
        case nil: "—"
        }
    }
    private var condition: String {
        switch details?.condition.value {
        case .checkBattery: l10n.text("Требуется проверка аккумулятора")
        case .permanentFailure: l10n.text("Требуется замена аккумулятора")
        case nil: "—"
        }
    }
}

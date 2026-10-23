import SwiftUI
import EcosystemLocalization
import MacAssistantCore

struct NetworkView: View {
    @Environment(\.agentLanguage) private var language
    @StateObject private var model: NetworkViewModel
    @State private var visible = false
    @State private var paused = false
    init(container: AppContainer) { _model = StateObject(wrappedValue: NetworkViewModel(provider: container.services.liveMonitoring)) }
    var body: some View {
        NetworkContent(model: model, paused: paused || !visible)
            .navigationTitle(AthenaLocalization(language: language).text("Сеть"))
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

struct NetworkContent: View {
    @Environment(\.agentLanguage) private var language
    @ObservedObject var model: NetworkViewModel
    var paused = false
    private var l10n: AthenaLocalization { AthenaLocalization(language: language) }
    private var dimmed: Bool { paused || model.suspended || model.runtimeError != nil || model.sample?.stale == true }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                status
                Picker(l10n.text("Интерфейс"), selection: $model.selectedInterface) {
                    if model.interfaces.isEmpty { Text(l10n.text("Нет данных")).tag("") }
                    ForEach(model.interfaces, id: \.id) { Text($0.id).tag($0.id) }
                }.pickerStyle(.menu).frame(maxWidth: 350, alignment: .leading)
                Text(l10n.text("Трафик выбранного интерфейса. VPN и физические интерфейсы учитываются отдельно."))
                    .font(.caption).foregroundStyle(.secondary)
                HStack(spacing: 16) {
                    rateCard(l10n.text("Приём"), model.metrics?.receivedBytesPerSecond.value)
                    rateCard(l10n.text("Передача"), model.metrics?.sentBytesPerSecond.value)
                }.opacity(dimmed ? 0.6 : 1)
                GroupBox(l10n.text("График сетевого трафика")) {
                    VStack(alignment: .leading, spacing: 12) {
                        Picker(l10n.text("Период графика"), selection: $model.historyWindow) {
                            Text(l10n.text("1 мин")).tag(ProcessorHistoryWindow.minute)
                            Text(l10n.text("5 мин")).tag(ProcessorHistoryWindow.fiveMinutes)
                            Text(l10n.text("15 мин")).tag(ProcessorHistoryWindow.fifteenMinutes)
                        }.pickerStyle(.segmented).labelsHidden().accessibilityLabel(l10n.text("Период графика")).frame(maxWidth: 260)
                        NetworkChart(model: model).opacity(dimmed ? 0.6 : 1)
                    }.padding(8)
                }
                interfaceDetails.opacity(dimmed ? 0.6 : 1)
                globalConfiguration.opacity(dimmed ? 0.6 : 1)
            }.padding(20)
        }
    }
    private var status: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let error = model.runtimeError { Text(l10n.render(.runtime(error))) }
            else if model.suspended { Text(l10n.text("Мониторинг остановлен аварийной кнопкой. Возобновите его в настройках.")) }
            else if paused { Text(l10n.text("Обновление приостановлено")) }
            else if model.sample?.stale == true { Text(l10n.text("Данные устарели. Ожидание свежего измерения.")) }
            else if model.metrics?.receivedBytesPerSecond.state == .warmingUp || model.sample == nil { Text(l10n.text("Накопление измерений")) }
            else if let sample = model.sample, sample.state != .available { Text(AthenaMetricPresentation.stateTitle(sample.state, using: l10n)) }
            else { Text(l10n.text("Обновление каждую секунду")) }
            if let sample = model.sample { Text(l10n.format("Обновлено: %@", sample.capturedAt.formatted(date: .omitted, time: .standard))).font(.caption).foregroundStyle(.secondary) }
            if let summary = model.summary, summary.omittedInterfaces > 0 {
                Text(l10n.format("Интерфейсов обнаружено: %@ · не показано: %@", summary.observedInterfaces.formatted(), summary.omittedInterfaces.formatted())).font(.caption)
            }
        }.accessibilityElement(children: .combine)
    }
    private func rateCard(_ title: String, _ value: Double?) -> some View {
        GroupBox { VStack(alignment: .leading, spacing: 8) {
            Text(title).foregroundStyle(.secondary)
            Text(NetworkFormat.rate(value, language: language)).font(.title2.weight(.semibold)).monospacedDigit()
        }.frame(maxWidth: .infinity, alignment: .leading).padding(4) }.accessibilityElement(children: .combine)
    }
    private var interfaceDetails: some View {
        GroupBox(l10n.text("Данные интерфейса")) {
            VStack(alignment: .leading, spacing: 10) {
                if let details = model.metrics?.details {
                    LabeledContent(l10n.text("Состояние"), value: details.up ? l10n.text("Интерфейс включён") : l10n.text("Интерфейс выключен"))
                    if details.loopback { Text(l10n.text("Локальный loopback-интерфейс")).font(.caption) }
                    if details.pointToPoint { Text(l10n.text("Соединение точка-точка / туннель")).font(.caption) }
                    LabeledContent(l10n.text("MTU"), value: details.mtu.formatted())
                    LabeledContent(l10n.text("Получено всего"), value: NetworkFormat.bytes(details.receivedBytes, language: language))
                    LabeledContent(l10n.text("Отправлено всего"), value: NetworkFormat.bytes(details.sentBytes, language: language))
                    LabeledContent(l10n.text("Пакеты: приём / передача"), value: details.receivedPackets.formatted() + " / " + details.sentPackets.formatted())
                    LabeledContent(l10n.text("Ошибки: приём / передача"), value: details.receivedErrors.formatted() + " / " + details.sentErrors.formatted())
                    Text(l10n.text("Накопленные счётчики могут сбрасываться при переподключении интерфейса.")).font(.caption).foregroundStyle(.secondary)
                }
                LabeledContent(l10n.text("Локальные IPv4 / IPv6"), value: model.metrics?.configuration?.addresses.value.map { $0.isEmpty ? l10n.text("Адресов нет") : $0.joined(separator: ", ") } ?? "—")
                    .textSelection(.enabled)
                if let wifi = model.metrics?.configuration?.wifi {
                    Divider()
                    LabeledContent(l10n.text("Wi-Fi"), value: wifi.powered ? l10n.text("Включён") : l10n.text("Выключен"))
                    LabeledContent(l10n.text("Сигнал RSSI, дБм"), value: wifi.rssiDBm.map(String.init) ?? "—")
                    LabeledContent(l10n.text("Шум, дБм"), value: wifi.noiseDBm.map(String.init) ?? "—")
                    LabeledContent(l10n.text("Канал Wi-Fi"), value: wifi.channel.map(String.init) ?? "—")
                    LabeledContent(l10n.text("Скорость радиолинка, Мбит/с"), value: wifi.linkMegabitsPerSecond.map { $0.formatted(.number.precision(.fractionLength(1)).locale(Locale(identifier: language.rawValue))) } ?? "—")
                    Text(l10n.text("Радиолинк показывает скорость Wi-Fi соединения; фактический трафик отображается на графике.")).font(.caption).foregroundStyle(.secondary)
                }
            }.padding(8).frame(maxWidth: .infinity, alignment: .leading)
        }
    }
    private var globalConfiguration: some View {
        GroupBox(l10n.text("Системная конфигурация сети")) {
            VStack(alignment: .leading, spacing: 10) {
                LabeledContent(l10n.text("Основной IPv4-интерфейс"), value: model.summary?.primaryIPv4 ?? "—")
                LabeledContent(l10n.text("Основной IPv6-интерфейс"), value: model.summary?.primaryIPv6 ?? "—")
                LabeledContent(l10n.text("Шлюз IPv4"), value: model.summary?.routerIPv4.value ?? "—")
                LabeledContent(l10n.text("Шлюз IPv6"), value: model.summary?.routerIPv6.value ?? "—")
                LabeledContent(l10n.text("Глобальные DNS-серверы"), value: model.summary?.dnsServers.value?.joined(separator: ", ") ?? "—")
                Text(l10n.text("Параметры обновляются каждые 5 секунд. VPN может использовать отдельные маршруты и DNS.")).font(.caption).foregroundStyle(.secondary)
                if let date = model.summary?.configurationCapturedAt {
                    Text(l10n.format("Параметры обновлены: %@", date.formatted(date: .omitted, time: .standard))).font(.caption).foregroundStyle(.secondary)
                }
            }.textSelection(.enabled).padding(8).frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

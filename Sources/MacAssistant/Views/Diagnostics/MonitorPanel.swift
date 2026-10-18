import SwiftUI
import MacAssistantCore
import EcosystemLocalIPC

struct MonitorPanel: View {
    @StateObject private var model: MonitorViewModel
    init(client: Result<LocalRPCClient, Error>?) { _model = StateObject(wrappedValue: MonitorViewModel(client: client)) }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Локальный мониторинг").font(.title2)
                Spacer()
                Button("Обновить мониторинг") { Task { await model.refresh() } }
                Menu("Добавить проверку") {
                    Button("CPU") { Task { await model.create(.cpu) } }
                    Button("Накопитель") { Task { await model.create(.storage) } }
                    Button("Давление памяти") { Task { await model.create(.memoryPressure) } }
                }
            }
            Text("Работает без модели и открытого окна. Системные уведомления будут подключены на этапе постоянной автоматизации.").font(.caption).foregroundStyle(.secondary)
            if let error = model.error { Text(error).foregroundStyle(.red) }
            List {
                ForEach(model.entries) { entry in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(entry.rule.name)
                            Text(entry.enabled ? status(entry.state.status) : "Выключено").foregroundStyle(.secondary)
                        }
                        Spacer()
                        if entry.enabled { Button("Выключить") { Task { await model.disable(entry.id) } } }
                        else { Button("Запросить включение") { Task { await model.request(entry.id) } } }
                    }
                }
                ForEach(model.plans) { plan in
                    Button("Проверить план мониторинга") { model.reviewing = plan }
                        .accessibilityIdentifier("monitor.review")
                }
                Section("Последние переходы состояния") {
                    ForEach(model.history.prefix(20)) { event in
                        Text("\(event.capturedAt.formatted()) · \(status(event.status))")
                    }
                }
            }
        }
        .padding()
        .task { await model.refresh() }
        .sheet(item: $model.reviewing) { plan in
            VStack(alignment: .leading, spacing: 14) {
                Text("Подтвердить мониторинг").font(.title2)
                if let rule = model.entries.first(where: { $0.id == plan.monitorID })?.rule {
                    Text(rule.name)
                    Text("Показатель: \(rule.metric.rawValue)\nИнтервал: \(rule.intervalSeconds) с\nОкно: \(rule.windowSamples) измерения\nПорог предупреждения: \(rule.warning.formatted())\nКритический порог: \(rule.critical.formatted())\nВосстановление: ≤ \(rule.recovery.formatted())\nПауза повторных уведомлений: \(rule.cooldownSeconds) с")
                    if rule.metric == .memoryPressure { Text("Процент занятой RAM не используется. Недоступный pressure означает отсутствие измерения.") }
                }
                Text("Срок плана: \(plan.expiresAt.formatted())")
                if let error = model.error { Text(error).foregroundStyle(.red) }
                HStack {
                    Button("Отмена") { model.reviewing = nil }
                    Button("Подтвердить мониторинг") { Task { await model.approve(plan) } }
                        .accessibilityIdentifier("monitor.approve")
                }
            }.padding(24).frame(width: 500)
        }
    }
    private func status(_ value: MonitorStatus) -> String {
        switch value {
        case .normal: "Норма"
        case .warmingUp: "Накопление измерений"
        case .warning: "Предупреждение"
        case .critical: "Критическое состояние"
        case .recovered: "Восстановлено"
        case .unavailable: "Измерение недоступно"
        }
    }
}

import SwiftUI
import MacAssistantCore
import EcosystemLocalIPC
import EcosystemLocalization

struct MonitorPanel: View {
    @Environment(\.agentLanguage) private var language
    private var l10n: AthenaLocalization { AthenaLocalization(language: language) }
    @StateObject private var model: MonitorViewModel
    init(client: Result<LocalRPCClient, Error>?) { _model = StateObject(wrappedValue: MonitorViewModel(client: client)) }
    init(model: MonitorViewModel) { _model = StateObject(wrappedValue: model) }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(l10n.text("Локальный мониторинг")).font(.title2).accessibilityAddTraits(.isHeader)
                Spacer()
                Button(l10n.text("Обновить мониторинг")) { Task { await model.refresh() } }
                Menu(l10n.text("Добавить проверку")) {
                    Button(l10n.text("CPU")) { Task { await model.create(.cpu, language: language) } }
                    Button(l10n.text("Накопитель")) { Task { await model.create(.storage, language: language) } }
                    Button(l10n.text("Давление памяти")) { Task { await model.create(.memoryPressure, language: language) } }
                }
            }
            Text(l10n.text("Работает без модели и открытого окна. Уведомления зависят от настроек фоновой работы и разрешения macOS.")).font(.caption).foregroundStyle(.secondary)
            if let message = model.runtimeError {
                Text(AgentLocalization(language: language).runtimeMessage(message)).foregroundStyle(.red)
            } else if let error = model.error { Text(error).foregroundStyle(.red) }
            List {
                ForEach(model.entries) { entry in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(entry.rule.name)
                            Text(entry.enabled ? status(entry.state.status) : l10n.text("Выключено")).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if entry.enabled { Button(l10n.text("Выключить")) { Task { await model.disable(entry.id) } } }
                        else { Button(l10n.text("Запросить включение")) { Task { await model.request(entry.id) } } }
                    }
                }
                ForEach(model.plans) { plan in
                    Button(l10n.text("Проверить план мониторинга")) { model.reviewing = plan }
                        .accessibilityIdentifier("monitor.review")
                }
                Section(l10n.text("Последние переходы состояния")) {
                    ForEach(model.history.prefix(20)) { event in
                        Text(l10n.format("%@ · %@", event.capturedAt.formatted(), status(event.status)))
                    }
                }
            }
        }
        .padding()
        .task { await model.refresh() }
        .sheet(item: $model.reviewing) { plan in
            MonitorReviewView(model: model, plan: plan, language: language).id(plan.id)
        }
    }
    private func status(_ value: MonitorStatus) -> String {
        l10n.text(MonitorPresentation.statusTitle(value))
    }
}

/// Текст решения фиксируется при открытии плана, чтобы смена языка не меняла
/// смысл уже читаемого подтверждения. Новый plan.id создаёт новый снимок языка.
private struct MonitorReviewView: View {
    @ObservedObject var model: MonitorViewModel
    let plan: MonitorPlan
    @State private var confirmationLanguage: ConfirmationLanguage
    init(model: MonitorViewModel, plan: MonitorPlan, language: AgentLanguage) {
        self.model = model
        self.plan = plan
        _confirmationLanguage = State(initialValue: ConfirmationLanguage(language: language))
    }
    var body: some View {
        MonitorReviewContent(
            rule: model.entries.first(where: { $0.id == plan.monitorID })?.rule,
            expiresAt: plan.expiresAt, error: model.error, runtimeError: model.runtimeError,
            l10n: AthenaLocalization(language: confirmationLanguage.language),
            cancel: { model.reviewing = nil }, approve: { Task { await model.approve(plan) } }
        ).padding(24).frame(width: 500)
    }
}

/// Единственное содержимое реального подтверждения и снимков UI; callbacks
/// сохраняют исходные RPC, plan fingerprint и отдельное подтверждение GUI.
struct MonitorReviewContent: View {
    let rule: MonitorRule?
    let expiresAt: Date
    let error: String?
    var runtimeError: RuntimeMessage? = nil
    let l10n: AthenaLocalization
    var cancel: () -> Void = {}
    var approve: () -> Void = {}
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(l10n.text("Подтвердить мониторинг")).font(.title2).accessibilityAddTraits(.isHeader)
            if let rule {
                Text(rule.name)
                Text(l10n.format("Показатель: %@\nИнтервал: %@ с\nОкно, число измерений: %@\nПорог предупреждения: %@\nКритический порог: %@\nВосстановление: ≤ %@\nПауза повторных уведомлений: %@ с",
                    l10n.text(MonitorViewModel.metricTitle(rule.metric)), rule.intervalSeconds.formatted(),
                    rule.windowSamples.formatted(), rule.warning.formatted(), rule.critical.formatted(),
                    rule.recovery.formatted(), rule.cooldownSeconds.formatted()))
                if rule.metric == .memoryPressure {
                    Text(l10n.text("Процент занятой RAM не используется. Недоступный pressure означает отсутствие измерения."))
                }
            }
            Text(l10n.format("Срок плана: %@", expiresAt.formatted()))
            if let runtimeError {
                Text(AgentLocalization(language: l10n.language).runtimeMessage(runtimeError)).foregroundStyle(.red)
            } else if let error { Text(error).foregroundStyle(.red) }
            HStack {
                Button(l10n.text("Отмена"), role: .cancel, action: cancel)
                    .keyboardShortcut(.cancelAction)
                Button(l10n.text("Подтвердить мониторинг"), action: approve)
                    .accessibilityIdentifier("monitor.approve")
            }
        }
    }
}

enum MonitorPresentation {
    static func statusTitle(_ value: MonitorStatus) -> String {
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

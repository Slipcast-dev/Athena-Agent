import Foundation
import MacAssistantCore
import EcosystemLocalIPC
import EcosystemLocalization

/// GUI отображает серверный план; выдача разрешения не выводится из состояния
/// кнопки. После подтверждения заново загружаются persistent настройки runtime.
@MainActor final class MonitorViewModel: ObservableObject {
    @Published var entries: [MonitorEntry] = []
    @Published var plans: [MonitorPlan] = []
    @Published var history: [MonitorEvent] = []
    @Published var reviewing: MonitorPlan?
    @Published var error: String?
    @Published private(set) var runtimeError: RuntimeMessage?
    private let client: Result<LocalRPCClient, Error>?
    init(client: Result<LocalRPCClient, Error>?) { self.client = client }
    static func metricTitle(_ metric: MonitorMetric) -> String {
        switch metric {
        case .cpu: "CPU"
        case .storage: "Накопитель"
        case .memoryPressure: "Давление памяти"
        }
    }
    func refresh() async {
        do {
            guard let client else { return }
            let rpc = try client.get()
            let page: MonitorPage = try await rpc.call("monitor.list", MonitorRequest())
            entries = page.items
            plans = try await rpc.call("monitor.pending", MonitorRequest())
            let events: MonitorHistoryPage = try await rpc.call("monitor.history", MonitorRequest())
            history = events.items; error = nil; runtimeError = nil
        } catch {
            self.error = error.localizedDescription
            runtimeError = RuntimeMessage.capture(error)
        }
    }
    func create(_ metric: MonitorMetric, language: AgentLanguage = .russian) async {
        do {
            guard let client else { return }
            var rule = MonitorRule(); rule.metric = metric
            // Локализуется только новое имя; сохранённое имя и fingerprint не переписываются.
            let l10n = AthenaLocalization(language: language)
            rule.name = l10n.format("Проверка %@", l10n.text(Self.metricTitle(metric)))
            if metric == .storage { rule.critical = 90 }
            if metric == .memoryPressure { rule.warning = 1; rule.critical = 2; rule.recovery = 0 }
            let entry: MonitorEntry = try await client.get().call("monitor.propose", MonitorRequest(rule: rule))
            let plan: MonitorPlan = try await client.get().call("monitor.request_enable", MonitorRequest(monitorID: entry.id))
            await refresh(); reviewing = plan
        } catch {
            self.error = error.localizedDescription
            runtimeError = RuntimeMessage.capture(error)
        }
    }
    func request(_ id: UUID) async {
        do {
            guard let client else { return }
            reviewing = try await client.get().call("monitor.request_enable", MonitorRequest(monitorID: id))
            await refresh()
        } catch {
            self.error = error.localizedDescription
            runtimeError = RuntimeMessage.capture(error)
        }
    }
    func approve(_ plan: MonitorPlan) async {
        do {
            guard let client else { return }
            let _: MonitorEntry = try await client.get().call("monitor.approve", MonitorRequest(planID: plan.id, fingerprint: plan.fingerprint))
            reviewing = nil; await refresh()
        } catch {
            self.error = error.localizedDescription
            runtimeError = RuntimeMessage.capture(error)
        }
    }
    func disable(_ id: UUID) async {
        do {
            guard let client else { return }
            let _: MonitorEntry = try await client.get().call("monitor.disable", MonitorRequest(monitorID: id))
            await refresh()
        } catch {
            self.error = error.localizedDescription
            runtimeError = RuntimeMessage.capture(error)
        }
    }
}

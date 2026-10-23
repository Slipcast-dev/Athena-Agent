import Foundation
import EcosystemLocalization
import EcosystemLocalIPC
import MacAssistantCore

@MainActor
final class BatteryViewModel: ObservableObject {
    @Published var historyWindow = ProcessorHistoryWindow.minute
    @Published private(set) var sample: MonitoringSample?
    @Published private(set) var history: [MonitoringHistoryPoint] = []
    @Published private(set) var suspended = false
    @Published private(set) var runtimeError: RuntimeMessage?
    private let provider: any LiveMonitoringProviding
    private let clock: MonitoringClock
    private let sleep: @Sendable (TimeInterval) async throws -> Void
    private var session: UUID?

    init(provider: any LiveMonitoringProviding, clock: MonitoringClock = .live,
         sleep: @escaping @Sendable (TimeInterval) async throws -> Void = { seconds in
             try await Task.sleep(for: .seconds(seconds), tolerance: .milliseconds(50))
         }) {
        self.provider = provider; self.clock = clock; self.sleep = sleep
    }

    var metrics: BatteryMonitoringMetrics? {
        guard case .battery(let value) = sample?.payload else { return nil }
        return value
    }
    var chartPoints: [BatteryChartPoint] { BatteryChartPoint.make(history) }

    /// У каждого окна своя lease и UI state, но общий provider/collector.
    /// UUID отделяет уходящую View.task от новой при быстром переключении вкладок.
    func runWhileVisible() async {
        guard !Task.isCancelled else { return }
        let token = UUID(); session = token
        var lease: MonitoringLease?
        var renewAt: TimeInterval = 0
        var retryDelay: TimeInterval = 1
        while !Task.isCancelled, session == token {
            do {
                var snapshot = try await provider.snapshot()
                try checkSession(token)
                if snapshot.suspended {
                    if let old = lease { await release(old.id); lease = nil }
                } else {
                    if lease == nil {
                        lease = try await provider.subscribe(groups: [.battery])
                        renewAt = clock.now().monotonic + 5
                        // Снимок после подписки может уже содержать первую выборку батареи.
                        snapshot = try await provider.snapshot()
                    } else if let current = lease, clock.now().monotonic >= renewAt {
                        lease = try await provider.renew(current.id)
                        renewAt = clock.now().monotonic + 5
                    }
                }
                try checkSession(token)
                let rows = try await provider.history(.init(group: .battery, windowSeconds: historyWindow.rawValue))
                try checkSession(token)
                accept(snapshot: snapshot, history: rows)
                runtimeError = nil; retryDelay = 1
            } catch is CancellationError { break }
            catch {
                guard session == token, !Task.isCancelled else { break }
                runtimeError = .capture(error)
                // После restart/expiry сервер не возобновляет старый UUID.
                // Новая подписка создаётся в следующем цикле с ограниченным backoff.
                if let old = lease { await release(old.id); lease = nil }
                retryDelay = min(15, retryDelay * 2)
            }
            do { try await sleep(retryDelay) } catch { break }
        }
        if let lease { await release(lease.id) }
        if session == token { session = nil }
    }

    /// История содержит только заряд; остальные показатели — текущий снимок.
    func accept(snapshot: MonitoringSnapshot, history: [MonitoringHistoryPoint]) {
        sample = snapshot.samples.first { $0.group == .battery }
        self.history = history; suspended = snapshot.suspended
    }

    private func checkSession(_ token: UUID) throws {
        try Task.checkCancellation()
        guard session == token else { throw CancellationError() }
    }
    private func release(_ id: UUID) async {
        let provider = self.provider
        // Родитель уже может быть отменён. Независимый короткий cleanup даёт XPC
        // шанс снять lease немедленно; TTL остаётся страховкой ошибки транспорта.
        await Task.detached { try? await provider.unsubscribe(id) }.value
    }
}

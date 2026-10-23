import Foundation
import EcosystemLocalization
import EcosystemLocalIPC
import MacAssistantCore

@MainActor
final class MemoryViewModel: ObservableObject {
    @Published var historyWindow = ProcessorHistoryWindow.minute
    @Published var search = ""
    @Published var applications = true
    @Published var sortByName = false
    @Published private(set) var processSample: MonitoringSample?
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

    var metrics: MemoryMonitoringMetrics? {
        guard case .memory(let value) = sample?.payload else { return nil }
        return value
    }
    var processRows: [ProcessMemoryMetrics] {
        guard case .processes(let rows, _) = processSample?.payload else { return [] }
        return rows
    }
    var processSummary: ProcessMemorySummary? {
        guard case .processes(_, let summary) = processSample?.payload else { return nil }
        return summary
    }
    var rows: [MemoryDisplayRow] {
        // Неатрибутированный отказ или усечение может скрыть helper любого app.
        // Не выдаём известную сумму такого bundle за полное потребление.
        let incomplete = (processSummary?.omitted ?? 0) > 0 || processSummary?.enumerationComplete == false ||
            processRows.contains { $0.footprintBytes.value == nil && $0.applicationID == nil }
        return MemoryDisplayRow.make(processRows, applications: applications, search: search,
                                     sortByName: sortByName, coverageIncomplete: incomplete)
    }
    var chartPoints: [MemoryChartPoint] { MemoryChartPoint.make(history) }

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
                        lease = try await provider.subscribe(groups: [.memory, .processes])
                        renewAt = clock.now().monotonic + 5
                        // Снимок после подписки может уже содержать первую RAM-выборку.
                        snapshot = try await provider.snapshot()
                    } else if let current = lease, clock.now().monotonic >= renewAt {
                        lease = try await provider.renew(current.id)
                        renewAt = clock.now().monotonic + 5
                    }
                }
                try checkSession(token)
                let rows = try await provider.history(.init(group: .memory, windowSeconds: historyWindow.rawValue))
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

    /// Каналы имеют отдельные timestamp: обновление RAM не делает старую
    /// таблицу процессов свежей. Имена остаются только в последнем снимке.
    func accept(snapshot: MonitoringSnapshot, history: [MonitoringHistoryPoint]) {
        sample = snapshot.samples.first { $0.group == .memory }
        processSample = snapshot.samples.first { $0.group == .processes }
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

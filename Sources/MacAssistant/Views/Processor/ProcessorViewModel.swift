import Foundation
import EcosystemLocalization
import EcosystemLocalIPC
import MacAssistantCore

/// Диапазон — только фильтр истории. Его смена не пересоздаёт sampler/lease.
enum ProcessorHistoryWindow: Int, CaseIterable, Identifiable {
    case minute = 60, fiveMinutes = 300, fifteenMinutes = 900
    var id: Int { rawValue }
    var title: String {
        switch self { case .minute: "1 мин"; case .fiveMinutes: "5 мин"; case .fifteenMinutes: "15 мин" }
    }
}

enum ProcessorSeries: String, CaseIterable {
    case total, user, system, core
    var title: String {
        switch self { case .total: "Общая нагрузка"; case .user: "Пользователь"; case .system: "Система"; case .core: "Ядро" }
    }
}

struct ProcessorChartPoint: Identifiable {
    let id: String
    let date: Date
    let value: Double
    let series: ProcessorSeries
    let segment: String
}

/// Превращает отсутствующие измерения в разные series сегменты Swift Charts.
/// Простого удаления nil недостаточно: LineMark иначе соединит края разрыва.
enum ProcessorChartData {
    static func points(_ history: [MonitoringHistoryPoint], core: Int?) -> [ProcessorChartPoint] {
        let series: [(ProcessorSeries, String)] = core.map { [(.core, "core.\($0)")] }
            ?? [(.total, "total"), (.user, "user"), (.system, "system")]
        var output: [ProcessorChartPoint] = []
        for (kind, key) in series {
            var segment = 0
            var previousDate: Date?
            for (index, point) in history.enumerated() {
                guard point.state == .available, let value = point.values[key], value.isFinite, (0...100).contains(value) else {
                    segment += 1; previousDate = nil; continue
                }
                if let previousDate, point.capturedAt <= previousDate { segment += 1 }
                previousDate = point.capturedAt
                output.append(ProcessorChartPoint(id: "\(key).\(index).\(point.capturedAt.timeIntervalSince1970)",
                    date: point.capturedAt, value: value, series: kind, segment: "\(key).\(segment)"))
            }
        }
        return output
    }
}

@MainActor
final class ProcessorViewModel: ObservableObject {
    @Published var historyWindow = ProcessorHistoryWindow.minute
    @Published var selectedCore: Int?
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

    var metrics: CPUMonitoringMetrics? {
        guard case .cpu(let data) = sample?.payload else { return nil }
        return data
    }
    var chartPoints: [ProcessorChartPoint] { ProcessorChartData.points(history, core: selectedCore) }

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
                        lease = try await provider.subscribe(groups: [.cpu])
                        renewAt = clock.now().monotonic + 5
                        // Первая baseline может уже содержать список ядер, даже
                        // когда проценты ещё warmingUp; показываем этот снимок сразу.
                        snapshot = try await provider.snapshot()
                    } else if let current = lease, clock.now().monotonic >= renewAt {
                        lease = try await provider.renew(current.id)
                        renewAt = clock.now().monotonic + 5
                    }
                }
                try checkSession(token)
                let rows = try await provider.history(.init(group: .cpu, windowSeconds: historyWindow.rawValue))
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

    /// Детерминированный seam для presentation/рендеринга и единственная точка
    /// применения снимка: при смене topology старый выбор ядра сбрасывается.
    func accept(snapshot: MonitoringSnapshot, history: [MonitoringHistoryPoint]) {
        sample = snapshot.samples.first { $0.group == .cpu }
        self.history = history; suspended = snapshot.suspended
        if let core = selectedCore, core < 0 || core >= (metrics?.cores.count ?? 0) { selectedCore = nil }
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

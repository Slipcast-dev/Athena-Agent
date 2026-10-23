import Foundation

public protocol ApplicationInventoryScanning: Sendable { func scan() async throws -> ApplicationInventoryMetrics }
public protocol MonitoringCacheInvalidating: MonitoringCollecting { func invalidateCache() async }

/// Отдельный медленный канал не задерживает capacity/CPU/RAM. Cache живёт только
/// в RAM. Reset lease после смены страницы не требует повторного обхода; явное
/// обновление и TTL инвалидируют результат. Epoch отсекает некооперативный scan.
public actor ApplicationInventoryCollector: MonitoringCacheInvalidating {
    public nonisolated let group = MonitoringGroup.applications
    private let scanner: any ApplicationInventoryScanning
    private let clock: MonitoringClock
    private var cache: (value: ApplicationInventoryMetrics, time: Double)?
    private var epoch: UInt64 = 0
    public init(scanner: any ApplicationInventoryScanning = POSIXApplicationInventoryScanner(), clock: MonitoringClock = .live) {
        self.scanner = scanner; self.clock = clock
    }
    public func invalidateCache() { cache = nil; epoch &+= 1 }
    public func collect(reset: Bool) async throws -> MonitoringCollection {
        try Task.checkCancellation()
        let now = clock.now().monotonic
        if let cache, now >= cache.time, now - cache.time < 300 {
            return .init(payload: .applications(cache.value), refreshAfter: 300 - (now - cache.time))
        }
        let generation = epoch
        let scanned = try await scanner.scan()
        try Task.checkCancellation()
        var rows = scanned.applications
        var value = scanned
        // Каталог ограничен ещё и байтами: большие имена не должны вытеснить
        // CPU/network/processes из общего bounded snapshot RPC.
        while (try JSONEncoder().encode(value)).count > 64_000, !rows.isEmpty {
            rows.removeLast()
            value = ApplicationInventoryMetrics(capturedAt: scanned.capturedAt, applications: rows, roots: scanned.roots,
                discoveredApplications: scanned.discoveredApplications, visitedEntries: scanned.visitedEntries,
                enumerationComplete: false, limitReached: true)
        }
        if generation == epoch { cache = (value, clock.now().monotonic) }
        return .init(payload: .applications(value), refreshAfter: 300)
    }
}

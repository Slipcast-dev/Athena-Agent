import Foundation
import XCTest
import EcosystemLocalIPC
@testable import MacAssistantCore

private final class InventoryTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var seconds: Double = 0
    var clock: MonitoringClock { MonitoringClock { self.now() } }
    func now() -> MonitoringInstant {
        lock.lock(); defer { lock.unlock() }
        return .init(monotonic: seconds, date: Date(timeIntervalSince1970: 1_700_000_000 + seconds))
    }
    func advance(_ value: Double) { lock.lock(); seconds += value; lock.unlock() }
}
private actor InventoryCountingScanner: ApplicationInventoryScanning {
    var calls = 0
    let clock: InventoryTestClock?
    init(clock: InventoryTestClock? = nil) { self.clock = clock }
    func scan() -> ApplicationInventoryMetrics {
        calls += 1; clock?.advance(60)
        return .init(capturedAt: Date(timeIntervalSince1970: Double(calls)), applications: [], roots: [],
                     discoveredApplications: 0, visitedEntries: 0, enumerationComplete: true, limitReached: false)
    }
}
private struct InventoryLargeScanner: ApplicationInventoryScanning {
    func scan() -> ApplicationInventoryMetrics {
        let rows = (0..<256).map { InstalledApplicationMetrics(id: String(format: "%064x", $0), name: String(repeating: "a", count: 256),
            location: .shared, logicalBytes: .init(UInt64($0)), allocatedBytes: .init(UInt64($0)), complete: true) }
        return .init(capturedAt: Date(), applications: rows, roots: [], discoveredApplications: 256,
                     visitedEntries: 256, enumerationComplete: true, limitReached: false)
    }
}
private actor InventoryBlockingScanner: ApplicationInventoryScanning {
    var calls = 0
    private var gate: CheckedContinuation<Void, Never>?
    private var watchers: [CheckedContinuation<Void, Never>] = []
    func scan() async -> ApplicationInventoryMetrics {
        calls += 1
        if calls == 1 {
            await withCheckedContinuation { gate = $0; watchers.forEach { $0.resume() }; watchers.removeAll() }
        }
        return .init(capturedAt: Date(timeIntervalSince1970: Double(calls)), applications: [], roots: [],
                     discoveredApplications: 0, visitedEntries: 0, enumerationComplete: true, limitReached: false)
    }
    func waitUntilStarted() async {
        if gate != nil { return }
        await withCheckedContinuation { watchers.append($0) }
    }
    func release() { gate?.resume(); gate = nil }
}

final class ApplicationInventoryCacheTests: XCTestCase {
    func testCacheSurvivesLeaseResetThenExpiresAndExplicitInvalidationWorks() async throws {
        let clock = InventoryTestClock(), scanner = InventoryCountingScanner()
        let collector = ApplicationInventoryCollector(scanner: scanner, clock: clock.clock)
        let first = try await collector.collect(reset: false)
        clock.advance(299)
        let cached = try await collector.collect(reset: true)
        XCTAssertEqual(first.payload, cached.payload)
        let once = await scanner.calls; XCTAssertEqual(once, 1)
        clock.advance(1); _ = try await collector.collect(reset: false)
        let twice = await scanner.calls; XCTAssertEqual(twice, 2)
        await collector.invalidateCache(); _ = try await collector.collect(reset: false)
        let three = await scanner.calls; XCTAssertEqual(three, 3)
    }
    func testSlowScanReportsRemainingTTLInsteadOfAnotherFullWindow() async throws {
        let clock = InventoryTestClock()
        let scanner = InventoryCountingScanner(clock: clock)
        let collector = ApplicationInventoryCollector(scanner: scanner, clock: clock.clock)
        let first = try await collector.collect(reset: false) // scanner advances 60 s
        XCTAssertEqual(first.refreshAfter, 300)
        clock.advance(240)
        let cached = try await collector.collect(reset: false)
        XCTAssertEqual(cached.refreshAfter, 60)
        let calls = await scanner.calls; XCTAssertEqual(calls, 1)
    }
    func testResubscribeCannotDeferExistingCacheExpiryByFiveMinutes() async throws {
        let clock = InventoryTestClock(), scanner = InventoryCountingScanner()
        let collector = ApplicationInventoryCollector(scanner: scanner, clock: clock.clock)
        let coordinator = MonitoringCoordinator(collectors: [collector], clock: clock.clock, automaticSampling: false)
        _ = try await coordinator.subscribe(groups: [.applications]); await coordinator.waitForCollections()
        clock.advance(290) // прежняя lease истекла, cache ещё свежий
        _ = try await coordinator.subscribe(groups: [.applications]); await coordinator.waitForCollections()
        let before = await scanner.calls; XCTAssertEqual(before, 1)
        clock.advance(10); await coordinator.poll(); await coordinator.waitForCollections()
        let after = await scanner.calls; XCTAssertEqual(after, 2)
        await coordinator.shutdown()
    }
    func testLateScanCannotRepopulateInvalidatedCache() async throws {
        let scanner = InventoryBlockingScanner()
        let actual = ApplicationInventoryCollector(scanner: scanner)
        let first = Task { try await actual.collect(reset: false) }
        await scanner.waitUntilStarted(); await actual.invalidateCache(); await scanner.release()
        _ = try await first.value
        _ = try await actual.collect(reset: false)
        let calls = await scanner.calls; XCTAssertEqual(calls, 2)
    }
    func testPayloadBudgetReportsTruncationInsteadOfBreakingSnapshot() async throws {
        let value = try await ApplicationInventoryCollector(scanner: InventoryLargeScanner()).collect(reset: false)
        guard case .applications(let data) = value.payload else { return XCTFail("Wrong payload") }
        XCTAssertLessThan(data.applications.count, 256); XCTAssertEqual(data.discoveredApplications, 256)
        XCTAssertFalse(data.enumerationComplete); XCTAssertTrue(data.limitReached)
        XCTAssertLessThanOrEqual(try JSONEncoder().encode(data).count, 64_000)
        XCTAssertTrue(value.payload?.validated() == true)
    }
    func testRefreshRequiresActiveSubscriberAndNeverResumesEmergencyStop() async throws {
        let collector = ApplicationInventoryCollector(scanner: InventoryCountingScanner())
        let coordinator = MonitoringCoordinator(collectors: [collector], automaticSampling: false)
        do { try await coordinator.refreshApplications(); XCTFail("Inactive refresh accepted") }
        catch { XCTAssertEqual(error as? LocalRuntimeFailure, .busy) }
        _ = try await coordinator.subscribe(groups: [.applications]); await coordinator.waitForCollections()
        try await coordinator.refreshApplications(); await coordinator.waitForCollections()
        await coordinator.suspend()
        do { try await coordinator.refreshApplications(); XCTFail("Stop bypass") }
        catch { XCTAssertEqual(error as? LocalRuntimeFailure, .busy) }
        let snapshot = await coordinator.snapshot(); XCTAssertTrue(snapshot.suspended)
        let history = try await coordinator.history(.init(group: .applications))
        XCTAssertTrue(history.isEmpty)
        await coordinator.shutdown()
    }
    func testCancelledCollectionDoesNotBeginScan() async throws {
        let scanner = InventoryCountingScanner()
        let actual = ApplicationInventoryCollector(scanner: scanner)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await actual.collect(reset: false)
        }
        do { _ = try await task.value; XCTFail("Cancelled scan accepted") } catch is CancellationError {}
        let calls = await scanner.calls; XCTAssertEqual(calls, 0)
    }
}

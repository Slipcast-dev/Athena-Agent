import Foundation
import Darwin
import XCTest
import EcosystemLocalIPC
import EcosystemRuntimeSupport
@testable import MacAssistantCore

/// Две независимые шкалы позволяют отличить перевод часов от истечения TTL.
private final class MonitoringTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var tick: Double = 0
    private var date = Date(timeIntervalSince1970: 1_700_000_000)
    var clock: MonitoringClock { MonitoringClock { self.read() } }
    func read() -> MonitoringInstant {
        lock.lock(); defer { lock.unlock() }
        return MonitoringInstant(monotonic: tick, date: date)
    }
    func advance(_ seconds: Double, wall: Double? = nil) {
        lock.lock(); defer { lock.unlock() }
        tick += seconds; date.addTimeInterval(wall ?? seconds)
    }
}

private actor MonitoringTestCollector: MonitoringCollecting {
    nonisolated let group: MonitoringGroup
    private let payload: MonitoringPayload
    private let blockFirst: Bool
    private let fail: Bool
    private var gate: CheckedContinuation<Void, Never>?
    private var started: [CheckedContinuation<Void, Never>] = []
    private(set) var resets: [Bool] = []

    init(group: MonitoringGroup = .cpu, payload: MonitoringPayload? = nil, blockFirst: Bool = false, fail: Bool = false) {
        self.group = group; self.payload = payload ?? .cpu(CPUMonitoringMetrics(totalPercent: .init(25)))
        self.blockFirst = blockFirst; self.fail = fail
    }
    func collect(reset: Bool) async throws -> MonitoringCollection {
        resets.append(reset)
        for continuation in started { continuation.resume() }; started.removeAll()
        // Намеренно некооперативный await: проверяем fencing и запрет перекрытия,
        // а не только правильное поведение идеального cancellation-aware source.
        if blockFirst && resets.count == 1 { await withCheckedContinuation { gate = $0 } }
        if fail { throw LocalRuntimeFailure.operationFailed }
        return MonitoringCollection(payload: payload)
    }
    func waitUntilStarted() async {
        if !resets.isEmpty { return }
        await withCheckedContinuation { started.append($0) }
    }
    func release() { gate?.resume(); gate = nil }
}

/// Источник системной границы: после первой выборки отдаёт известную нагрузку.
/// Создание нового экземпляра возвращает warmingUp независимо от CPU хоста.
private actor MonitoringCPUSequence: SystemInformationProviding {
    private var calls = 0
    func systemInfo() async throws -> SystemInfo { throw LocalRuntimeFailure.unavailable }
    func systemMetrics() async throws -> SystemMetrics {
        calls += 1
        return SystemMetrics(cpuState: calls == 1 ? .warmingUp : .available,
            cpuUsagePercent: calls == 1 ? nil : 25,
            totalMemoryBytes: 100, usedMemoryBytes: 50, availableMemoryBytes: 50,
            memoryPressure: nil, totalStorageBytes: 100, availableStorageBytes: 50)
    }
}

final class LiveMonitoringTests: XCTestCase {
    func testMissingAndMeasuredZeroRemainDistinctThroughWireRoundTrip() throws {
        let zero = MonitoringMetric<Double>(0)
        let warming = MonitoringMetric<Double>(state: .warmingUp)
        let missing = MonitoringMetric<Double>(state: .available)
        XCTAssertEqual(zero.state, .available); XCTAssertEqual(zero.value, 0)
        XCTAssertEqual(warming.state, .warmingUp); XCTAssertNil(warming.value)
        XCTAssertEqual(missing.state, .unavailable)
        XCTAssertEqual(try LocalWire.decode(MonitoringMetric<Double>.self, LocalWire.encode(warming)), warming)
    }

    func testMultipleWindowsShareOneSamplerAndLastUnsubscribeStopsIt() async throws {
        let clock = MonitoringTestClock(), source = MonitoringTestCollector()
        let coordinator = MonitoringCoordinator(collectors: [source], clock: clock.clock, automaticSampling: false)
        let one = try await coordinator.subscribe(groups: [.cpu])
        await coordinator.waitForCollections()
        let two = try await coordinator.subscribe(groups: [.cpu])
        await coordinator.waitForCollections()
        var resets = await source.resets; XCTAssertEqual(resets, [true])
        clock.advance(1); await coordinator.poll(); await coordinator.waitForCollections()
        resets = await source.resets; XCTAssertEqual(resets, [true, false])
        await coordinator.unsubscribe(one.id)
        clock.advance(1); await coordinator.poll(); await coordinator.waitForCollections()
        resets = await source.resets; XCTAssertEqual(resets.count, 3)
        await coordinator.unsubscribe(two.id)
        clock.advance(1); await coordinator.poll()
        resets = await source.resets; XCTAssertEqual(resets.count, 3)
        let snapshot = await coordinator.snapshot(); XCTAssertTrue(snapshot.samples.first { $0.group == .cpu }!.stale)
    }

    func testLeaseExpiryUsesMonotonicClockAndRenewalCannotReviveExpiredLease() async throws {
        let clock = MonitoringTestClock(), source = MonitoringTestCollector()
        let coordinator = MonitoringCoordinator(collectors: [source], clock: clock.clock, automaticSampling: false)
        let lease = try await coordinator.subscribe(groups: [.cpu]); await coordinator.waitForCollections()
        clock.advance(1, wall: -3600)
        _ = try await coordinator.renew(lease.id)
        clock.advance(15); await coordinator.poll()
        do { _ = try await coordinator.renew(lease.id); XCTFail("Expired lease revived") }
        catch { XCTAssertEqual(error as? LocalRuntimeFailure, .denied) }
        let resets = await source.resets; XCTAssertEqual(resets, [true])
        let newLease = try await coordinator.subscribe(groups: [.cpu]); await coordinator.waitForCollections()
        let renewed = await source.resets; XCTAssertEqual(renewed, [true, true])
        await coordinator.unsubscribe(newLease.id)
    }

    func testGroupIntervalsDoNotRunDiskAndProcessesAtCPUFrequency() async throws {
        let clock = MonitoringTestClock()
        let cpu = MonitoringTestCollector()
        let disk = MonitoringTestCollector(group: .disk, payload: .disk([]))
        let processes = MonitoringTestCollector(group: .processes, payload: .processes([]))
        let coordinator = MonitoringCoordinator(collectors: [cpu, disk, processes], clock: clock.clock, automaticSampling: false)
        _ = try await coordinator.subscribe(groups: [.cpu, .disk, .processes]); await coordinator.waitForCollections()
        for _ in 1...10 { clock.advance(1); await coordinator.poll(); await coordinator.waitForCollections() }
        let cpuCalls = await cpu.resets.count, diskCalls = await disk.resets.count, processCalls = await processes.resets.count
        XCTAssertEqual(cpuCalls, 11); XCTAssertEqual(diskCalls, 2); XCTAssertEqual(processCalls, 3)
    }

    func testSnapshotReadsDoNotCollectAndOldValuesBecomeStale() async throws {
        let clock = MonitoringTestClock(), source = MonitoringTestCollector()
        let coordinator = MonitoringCoordinator(collectors: [source], clock: clock.clock, automaticSampling: false)
        _ = try await coordinator.subscribe(groups: [.cpu]); await coordinator.waitForCollections()
        for _ in 0..<20 { _ = await coordinator.snapshot() }
        clock.advance(4)
        let snapshot = await coordinator.snapshot(), calls = await source.resets.count
        XCTAssertEqual(calls, 1); XCTAssertTrue(snapshot.samples.first { $0.group == .cpu }!.stale)
        XCTAssertEqual(snapshot.samples.first { $0.group == .network }!.state, .unavailable)
    }

    func testRingRetainsOnlyNewestCapacityAndReleasesRemovedElements() {
        var ring = MonitoringRing<Int>(capacity: 900)
        for value in 0..<10_000 { ring.append(value) }
        XCTAssertEqual(ring.count, 900); XCTAssertEqual(ring.elements, Array(9_100..<10_000))
        ring.removeFirst(); XCTAssertEqual(ring.first, 9_101); XCTAssertEqual(ring.count, 899)
    }

    func testHistoryIsBoundedByTimeAndPointLimitAndKeepsLatestPoint() async throws {
        let clock = MonitoringTestClock(), source = MonitoringTestCollector()
        let coordinator = MonitoringCoordinator(collectors: [source], clock: clock.clock, automaticSampling: false)
        let lease = try await coordinator.subscribe(groups: [.cpu]); await coordinator.waitForCollections()
        let initial = clock.read().date
        for second in 1...1000 {
            clock.advance(1)
            if second % 10 == 0 { _ = try await coordinator.renew(lease.id) }
            await coordinator.poll(); await coordinator.waitForCollections()
        }
        let minute = try await coordinator.history(.init(group: .cpu, windowSeconds: 60))
        XCTAssertEqual(minute.count, 61)
        XCTAssertEqual(minute.first?.capturedAt, initial.addingTimeInterval(940))
        let longest = try await coordinator.history(.init(group: .cpu, windowSeconds: 900))
        XCTAssertEqual(longest.count, 120)
        XCTAssertEqual(longest.first?.capturedAt, initial.addingTimeInterval(101))
        XCTAssertEqual(longest.last?.capturedAt, initial.addingTimeInterval(1000))
        clock.advance(901)
        let expired = try await coordinator.history(.init(group: .cpu, windowSeconds: 900))
        XCTAssertTrue(expired.isEmpty)
    }

    func testWakeAndLargeGapResetBaselineAndAddGraphGap() async throws {
        let clock = MonitoringTestClock(), source = MonitoringTestCollector()
        let coordinator = MonitoringCoordinator(collectors: [source], clock: clock.clock, automaticSampling: false)
        _ = try await coordinator.subscribe(groups: [.cpu]); await coordinator.waitForCollections()
        clock.advance(6); await coordinator.poll(); await coordinator.waitForCollections()
        await coordinator.invalidateBaselines(); await coordinator.poll(); await coordinator.waitForCollections()
        let resets = await source.resets; XCTAssertEqual(resets, [true, true, true])
        let history = try await coordinator.history(.init(group: .cpu))
        XCTAssertTrue(history.contains { $0.state == .warmingUp && $0.values.isEmpty })
        let snapshot = await coordinator.snapshot()
        XCTAssertNil(snapshot.samples.first { $0.group == .cpu }!.intervalSeconds)
    }

    func testWallClockJumpDoesNotResetMonotonicBaseline() async throws {
        let clock = MonitoringTestClock(), source = MonitoringTestCollector()
        let coordinator = MonitoringCoordinator(collectors: [source], clock: clock.clock, automaticSampling: false)
        _ = try await coordinator.subscribe(groups: [.cpu]); await coordinator.waitForCollections()
        clock.advance(1, wall: 10000); await coordinator.poll(); await coordinator.waitForCollections()
        let resets = await source.resets; XCTAssertEqual(resets, [true, false])
        let snapshot = await coordinator.snapshot()
        XCTAssertEqual(snapshot.samples.first { $0.group == .cpu }!.intervalSeconds, 1)
    }

    func testCancelledUncooperativeCollectorCannotPublishOrOverlapAfterResubscribe() async throws {
        let clock = MonitoringTestClock(), source = MonitoringTestCollector(blockFirst: true)
        let coordinator = MonitoringCoordinator(collectors: [source], clock: clock.clock, automaticSampling: false)
        let first = try await coordinator.subscribe(groups: [.cpu]); await source.waitUntilStarted()
        await coordinator.unsubscribe(first.id)
        _ = try await coordinator.subscribe(groups: [.cpu])
        await coordinator.poll()
        var resets = await source.resets; XCTAssertEqual(resets.count, 1)
        await source.release(); await coordinator.waitForCollections()
        var points = try await coordinator.history(.init(group: .cpu)); XCTAssertTrue(points.isEmpty)
        await coordinator.poll(); await coordinator.waitForCollections()
        resets = await source.resets; XCTAssertEqual(resets, [true, true])
        points = try await coordinator.history(.init(group: .cpu)); XCTAssertEqual(points.count, 1)
    }

    func testSlowCollectorDoesNotBlockAnotherGroupOrSnapshot() async throws {
        let source = MonitoringTestCollector(blockFirst: true)
        let disk = MonitoringTestCollector(group: .disk, payload: .disk([]))
        let coordinator = MonitoringCoordinator(collectors: [source, disk], automaticSampling: false)
        _ = try await coordinator.subscribe(groups: [.cpu, .disk]); await source.waitUntilStarted()
        // Snapshot должен вернуться ДО освобождения CPU gate, иначе тест зависнет.
        let snapshot = await coordinator.snapshot()
        XCTAssertEqual(snapshot.samples.count, MonitoringGroup.allCases.count)
        XCTAssertEqual(Set(snapshot.samples.map(\.group)), Set(MonitoringGroup.allCases))
        await disk.waitUntilStarted()
        await source.release(); await coordinator.waitForCollections()
    }

    func testFailureWrongChannelAndNonfiniteValuesDoNotPolluteSnapshotOrHistory() async throws {
        for source in [MonitoringTestCollector(fail: true),
                       MonitoringTestCollector(payload: .disk([])),
                       MonitoringTestCollector(payload: .cpu(CPUMonitoringMetrics(totalPercent: .init(.nan))))] {
            let coordinator = MonitoringCoordinator(collectors: [source], automaticSampling: false)
            _ = try await coordinator.subscribe(groups: [.cpu]); await coordinator.waitForCollections()
            let sample = await coordinator.snapshot().samples.first { $0.group == .cpu }!
            XCTAssertEqual(sample.state, .unavailable); XCTAssertNil(sample.payload)
            let history = try await coordinator.history(.init(group: .cpu))
            XCTAssertTrue(history.allSatisfy { $0.values.isEmpty })
            await coordinator.shutdown()
        }
    }

    func testProcessNamesAreNeverStoredInGraphHistory() async throws {
        let source = MonitoringTestCollector(group: .processes, payload: .processes([
            ProcessMemoryMetrics(pid: 42, name: "PRIVATE-PROCESS-NAME", footprintBytes: .init(1024))]))
        let coordinator = MonitoringCoordinator(collectors: [source], automaticSampling: false)
        _ = try await coordinator.subscribe(groups: [.processes]); await coordinator.waitForCollections()
        let history = try await coordinator.history(.init(group: .processes))
        XCTAssertTrue(history.isEmpty)
        await coordinator.shutdown()
    }

    func testLeaseCapacityCancellationAndShutdownAreEnforced() async throws {
        let source = MonitoringTestCollector()
        let coordinator = MonitoringCoordinator(collectors: [source], automaticSampling: false)
        for _ in 0..<16 { _ = try await coordinator.subscribe(groups: [.cpu]) }
        do { _ = try await coordinator.subscribe(groups: [.cpu]); XCTFail("Unlimited subscriptions") }
        catch { XCTAssertEqual(error as? LocalRuntimeFailure, .busy) }
        await coordinator.shutdown(); await coordinator.resume()
        do { _ = try await coordinator.subscribe(groups: [.cpu]); XCTFail("Closed coordinator restarted") }
        catch { XCTAssertEqual(error as? LocalRuntimeFailure, .busy) }
        let idle = MonitoringCoordinator(collectors: [source], automaticSampling: false)
        let cancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await idle.subscribe(groups: [.cpu])
        }
        do { _ = try await cancelled.value; XCTFail("Cancelled subscribe accepted") }
        catch is CancellationError {}
        let snapshot = await idle.snapshot(); XCTAssertTrue(snapshot.samples.allSatisfy(\.stale))
    }

    func testDownsamplingKeepsGapInsteadOfInventingContinuousMeasurements() async throws {
        let clock = MonitoringTestClock(), source = MonitoringTestCollector()
        let coordinator = MonitoringCoordinator(collectors: [source], clock: clock.clock, automaticSampling: false)
        let lease = try await coordinator.subscribe(groups: [.cpu]); await coordinator.waitForCollections()
        for second in 1...50 {
            clock.advance(1)
            if second % 10 == 0 { _ = try await coordinator.renew(lease.id) }
            if second == 23 { await coordinator.invalidateBaselines() }
            await coordinator.poll(); await coordinator.waitForCollections()
        }
        let reduced = try await coordinator.history(.init(group: .cpu, maximumPoints: 5))
        XCTAssertEqual(reduced.count, 5)
        XCTAssertTrue(reduced.contains { $0.state == .warmingUp && $0.values.isEmpty })
    }

    func testOversizedCollectorPayloadIsRejectedBeforeItEntersHistory() async throws {
        let rows = (0..<513).map { ProcessMemoryMetrics(pid: Int32($0 + 1), name: "Example", footprintBytes: .init(1)) }
        let source = MonitoringTestCollector(group: .processes, payload: .processes(rows))
        let coordinator = MonitoringCoordinator(collectors: [source], automaticSampling: false)
        _ = try await coordinator.subscribe(groups: [.processes]); await coordinator.waitForCollections()
        let sample = await coordinator.snapshot().samples.first { $0.group == .processes }!
        XCTAssertEqual(sample.state, .unavailable); XCTAssertNil(sample.payload)
        await coordinator.shutdown()
    }

    func testCollectorFinishingAfterFreshnessWindowCannotPublishOldReading() async throws {
        let clock = MonitoringTestClock(), source = MonitoringTestCollector(blockFirst: true)
        let coordinator = MonitoringCoordinator(collectors: [source], clock: clock.clock, automaticSampling: false)
        _ = try await coordinator.subscribe(groups: [.cpu]); await source.waitUntilStarted()
        clock.advance(4); await source.release(); await coordinator.waitForCollections()
        let sample = await coordinator.snapshot().samples.first { $0.group == .cpu }!
        XCTAssertEqual(sample.state, .warmingUp); XCTAssertNil(sample.payload)
        await coordinator.poll(); await coordinator.waitForCollections()
        let resets = await source.resets; XCTAssertEqual(resets, [true, true])
    }

    func testBasicCollectorResetCreatesNewIndependentSource() async throws {
        let source = BasicMonitoringCollector(group: .cpu, makeSystem: { MonitoringCPUSequence() })
        let first = try await source.collect(reset: false)
        XCTAssertEqual(first.state, .warmingUp)
        let measured = try await source.collect(reset: false)
        XCTAssertEqual(measured.state, .available)
        let reset = try await source.collect(reset: true)
        XCTAssertEqual(reset.state, .warmingUp)
    }

    func testRepeatedSystemSamplingBalancesHostPortReferences() async throws {
        let system = SystemInformationService()
        _ = try await system.systemMetrics() // прогреваем ленивые Foundation API
        let host = mach_host_self()
        defer { mach_port_deallocate(mach_task_self_, host) }
        var before: mach_port_urefs_t = 0, after: mach_port_urefs_t = 0
        XCTAssertEqual(mach_port_get_refs(mach_task_self_, host, mach_port_right_t(MACH_PORT_RIGHT_SEND), &before), KERN_SUCCESS)
        for _ in 0..<20 { _ = try await system.systemMetrics() }
        XCTAssertEqual(mach_port_get_refs(mach_task_self_, host, mach_port_right_t(MACH_PORT_RIGHT_SEND), &after), KERN_SUCCESS)
        XCTAssertEqual(after, before, "Every fast sample must release temporary host send rights")
    }

    func testRPCResponseByteLimitIsEnforcedForDenseHistory() async throws {
        let clock = MonitoringTestClock()
        let rows = (0..<32).map { index in
            NetworkInterfaceMetrics(id: String(repeating: "a", count: 60) + String(index),
                receivedBytesPerSecond: .init(123456789.1234567), sentBytesPerSecond: .init(123456789.1234567))
        }
        let source = MonitoringTestCollector(group: .network, payload: .network(rows))
        let coordinator = MonitoringCoordinator(collectors: [source], clock: clock.clock, automaticSampling: false)
        let lease = try await coordinator.subscribe(groups: [.network]); await coordinator.waitForCollections()
        for second in 1...120 {
            clock.advance(1)
            if second % 10 == 0 { _ = try await coordinator.renew(lease.id) }
            await coordinator.poll(); await coordinator.waitForCollections()
        }
        let large = LocalRPCRequest(domain: "athena", operation: "monitoring.history",
            payload: try LocalWire.encode(MonitoringHistoryQuery(group: .network, windowSeconds: 300)))
        do { _ = try await LiveMonitoringControl.handle(large, coordinator: coordinator); XCTFail("Unbounded response") }
        catch { XCTAssertEqual(error as? LocalRuntimeFailure, .invalidRequest) }
        let small = LocalRPCRequest(domain: "athena", operation: "monitoring.history",
            payload: try LocalWire.encode(MonitoringHistoryQuery(group: .network, maximumPoints: 2)))
        let bytes = try await LiveMonitoringControl.handle(small, coordinator: coordinator)
        XCTAssertLessThanOrEqual(bytes.count, LiveMonitoringControl.maximumResponseBytes)
    }

    func testOldEmergencyRevisionCannotUndoNewerResumeOrStop() async throws {
        let coordinator = MonitoringCoordinator(collectors: [], automaticSampling: false)
        await coordinator.synchronizeEmergency(suspended: true, revision: 2)
        await coordinator.synchronizeEmergency(suspended: false, revision: 1)
        var snapshot = await coordinator.snapshot(); XCTAssertTrue(snapshot.suspended)
        await coordinator.synchronizeEmergency(suspended: false, revision: 3)
        await coordinator.synchronizeEmergency(suspended: true, revision: 2)
        snapshot = await coordinator.snapshot(); XCTAssertFalse(snapshot.suspended)
    }
    func testBatteryUsesSharedFifteenSecondSamplingAndStopsAfterLastLease() async throws {
        let clock = MonitoringTestClock()
        let source = MonitoringTestCollector(group: .battery, payload: .battery(.init(present: .init(false))))
        let coordinator = MonitoringCoordinator(collectors: [source], clock: clock.clock, automaticSampling: false)
        let first = try await coordinator.subscribe(groups: [.battery])
        await coordinator.waitForCollections()
        let second = try await coordinator.subscribe(groups: [.battery])
        for tick in 1...15 {
            clock.advance(1)
            if tick % 5 == 0 { _ = try await coordinator.renew(second.id) }
            await coordinator.poll(); await coordinator.waitForCollections()
            let count = await source.resets.count
            XCTAssertEqual(count, tick < 15 ? 1 : 2)
        }
        await coordinator.unsubscribe(first.id); await coordinator.unsubscribe(second.id)
        clock.advance(15); await coordinator.poll(); await coordinator.waitForCollections()
        let finalCount = await source.resets.count
        XCTAssertEqual(finalCount, 2)
        let snapshot = await coordinator.snapshot()
        XCTAssertTrue(try XCTUnwrap(snapshot.samples.first { $0.group == .battery }).stale)
    }

}

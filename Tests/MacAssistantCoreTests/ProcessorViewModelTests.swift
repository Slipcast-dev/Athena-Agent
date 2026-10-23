import AppKit
import Foundation
import SwiftUI
import XCTest
import EcosystemLocalIPC
@testable import MacAssistantCore
@testable import MacAssistant

private final class ProcessorSessionClock: @unchecked Sendable {
    private let lock = NSLock()
    private var seconds: Double = 0
    var clock: MonitoringClock { MonitoringClock { self.now() } }
    func now() -> MonitoringInstant {
        lock.lock(); defer { lock.unlock() }
        return MonitoringInstant(monotonic: seconds, date: Date(timeIntervalSince1970: seconds + 1_700_000_000))
    }
    func advance(_ value: Double) { lock.lock(); seconds += value; lock.unlock() }
}

private actor ProcessorSessionSleeper {
    private let clock: ProcessorSessionClock
    private let maximum: Int
    private var calls = 0
    init(clock: ProcessorSessionClock, maximum: Int = 8) { self.clock = clock; self.maximum = maximum }
    func sleep(_ seconds: Double) throws {
        calls += 1; clock.advance(seconds)
        if calls >= maximum { throw CancellationError() }
    }
}

private actor ProcessorSessionProvider: LiveMonitoringProviding {
    var calls: [String] = []
    private let snapshotValue: MonitoringSnapshot
    private var renewedFailure = false
    private let failRenew: Bool
    private let suspendedFirst: Bool
    private var reads = 0
    init(suspended: Bool = false, failRenew: Bool = false, suspendedFirst: Bool = false) {
        self.snapshotValue = MonitoringSnapshot(suspended: suspended, samples: [])
        self.failRenew = failRenew; self.suspendedFirst = suspendedFirst
    }
    func subscribe(groups: Set<MonitoringGroup>) throws -> MonitoringLease {
        calls.append("subscribe")
        guard groups == [.cpu] else { throw LocalRuntimeFailure.invalidRequest }
        return MonitoringLease(id: UUID(), expiresAt: Date().addingTimeInterval(15))
    }
    func renew(_ id: UUID) throws -> MonitoringLease {
        calls.append("renew")
        if failRenew, !renewedFailure { renewedFailure = true; throw LocalRuntimeFailure.denied }
        return MonitoringLease(id: id, expiresAt: Date().addingTimeInterval(15))
    }
    func unsubscribe(_ id: UUID) { calls.append("unsubscribe") }
    func snapshot() -> MonitoringSnapshot {
        calls.append("snapshot"); reads += 1
        if suspendedFirst && reads == 1 { return MonitoringSnapshot(suspended: true, samples: []) }
        return snapshotValue
    }
    func history(_ query: MonitoringHistoryQuery) -> [MonitoringHistoryPoint] {
        calls.append("history.\(query.windowSeconds)"); return []
    }
}

private actor ProcessorBlockingSleep {
    private var gate: CheckedContinuation<Void, Never>?
    private var watchers: [CheckedContinuation<Void, Never>] = []
    func sleep(_ seconds: Double) async {
        await withCheckedContinuation { gate = $0; watchers.forEach { $0.resume() }; watchers.removeAll() }
    }
    func waitUntilSleeping() async {
        if gate != nil { return }
        await withCheckedContinuation { watchers.append($0) }
    }
    func release() { gate?.resume(); gate = nil }
}

@MainActor
final class ProcessorViewModelTests: XCTestCase {
    func testVisibleSessionRenewsAndClosesLeaseWithoutRealSleeps() async {
        let clock = ProcessorSessionClock(), provider = ProcessorSessionProvider()
        let sleeper = ProcessorSessionSleeper(clock: clock)
        let model = ProcessorViewModel(provider: provider, clock: clock.clock, sleep: { try await sleeper.sleep($0) })
        await model.runWhileVisible()
        let calls = await provider.calls
        XCTAssertEqual(calls.filter { $0 == "subscribe" }.count, 1)
        XCTAssertEqual(calls.filter { $0 == "renew" }.count, 1)
        XCTAssertEqual(calls.last, "unsubscribe")
        XCTAssertEqual(calls.filter { $0 == "history.60" }.count, 8)
    }
    func testCancelledSessionDoesNotSubscribe() async {
        let provider = ProcessorSessionProvider()
        let model = ProcessorViewModel(provider: provider)
        let task = Task { withUnsafeCurrentTask { $0?.cancel() }; await model.runWhileVisible() }
        await task.value
        let calls = await provider.calls; XCTAssertTrue(calls.isEmpty)
    }
    func testCancellingVisibleViewReleasesItsActualLease() async {
        let provider = ProcessorSessionProvider(), sleeper = ProcessorBlockingSleep()
        let model = ProcessorViewModel(provider: provider, sleep: { await sleeper.sleep($0) })
        let task = Task { await model.runWhileVisible() }
        await sleeper.waitUntilSleeping()
        task.cancel(); await sleeper.release(); await task.value
        let calls = await provider.calls
        XCTAssertEqual(calls.filter { $0 == "subscribe" }.count, 1)
        XCTAssertEqual(calls.filter { $0 == "unsubscribe" }.count, 1)
        XCTAssertEqual(calls.last, "unsubscribe")
    }
    func testExpiredLeaseCreatesNewSubscriptionAndCleansBoth() async {
        let clock = ProcessorSessionClock(), provider = ProcessorSessionProvider(failRenew: true)
        let sleeper = ProcessorSessionSleeper(clock: clock, maximum: 9)
        let model = ProcessorViewModel(provider: provider, clock: clock.clock, sleep: { try await sleeper.sleep($0) })
        await model.runWhileVisible()
        let calls = await provider.calls
        XCTAssertEqual(calls.filter { $0 == "subscribe" }.count, 2)
        XCTAssertEqual(calls.filter { $0 == "unsubscribe" }.count, 2)
        XCTAssertNil(model.runtimeError)
    }
    func testPersistentStopDoesNotSubscribeAndExplicitResumeCanBeObserved() async {
        let clock = ProcessorSessionClock(), provider = ProcessorSessionProvider(suspended: true)
        let sleeper = ProcessorSessionSleeper(clock: clock, maximum: 3)
        let model = ProcessorViewModel(provider: provider, clock: clock.clock, sleep: { try await sleeper.sleep($0) })
        await model.runWhileVisible()
        let calls = await provider.calls
        XCTAssertFalse(calls.contains("subscribe")); XCTAssertTrue(model.suspended)
        let resumed = ProcessorSessionProvider(suspendedFirst: true)
        let secondSleep = ProcessorSessionSleeper(clock: clock, maximum: 3)
        let second = ProcessorViewModel(provider: resumed, clock: clock.clock, sleep: { try await secondSleep.sleep($0) })
        await second.runWhileVisible()
        let resumedCalls = await resumed.calls
        XCTAssertEqual(resumedCalls.filter { $0 == "subscribe" }.count, 1)
        XCTAssertFalse(second.suspended)
    }
    func testHistoryRangeDoesNotChangeRequestedChannelAndTopologyClearsSelection() async {
        let clock = ProcessorSessionClock(), provider = ProcessorSessionProvider()
        let sleeper = ProcessorSessionSleeper(clock: clock, maximum: 2)
        let model = ProcessorViewModel(provider: provider, clock: clock.clock, sleep: { try await sleeper.sleep($0) })
        model.historyWindow = .fifteenMinutes
        await model.runWhileVisible()
        let calls = await provider.calls; XCTAssertTrue(calls.contains("history.900"))
        model.selectedCore = 9
        model.accept(snapshot: MonitoringSnapshot(suspended: false, samples: []), history: [])
        XCTAssertNil(model.selectedCore)
    }
    func testChartKeepsGapsAndSelectedCoreUsesOnlyItsOwnSeries() {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let rows = [
            MonitoringHistoryPoint(capturedAt: date, state: .available, values: ["total": 20, "user": 10, "system": 10, "core.0": 80]),
            MonitoringHistoryPoint(capturedAt: date.addingTimeInterval(1), state: .warmingUp, values: [:]),
            MonitoringHistoryPoint(capturedAt: date.addingTimeInterval(2), state: .available, values: ["total": 30, "user": 20, "system": 10, "core.0": 50]),
        ]
        let total = ProcessorChartData.points(rows, core: nil).filter { $0.series == .total }
        XCTAssertEqual(total.map(\.value), [20, 30]); XCTAssertNotEqual(total[0].segment, total[1].segment)
        let core = ProcessorChartData.points(rows, core: 0)
        XCTAssertEqual(core.map(\.value), [80, 50]); XCTAssertTrue(core.allSatisfy { $0.series == .core })
        let missing = ProcessorChartData.points(rows, core: 1); XCTAssertTrue(missing.isEmpty)
    }
    func testClockReversalAndInvalidValueDoNotJoinDifferentChartIntervals() {
        let date = Date()
        let rows = [
            MonitoringHistoryPoint(capturedAt: date, state: .available, values: ["total": 20]),
            MonitoringHistoryPoint(capturedAt: date.addingTimeInterval(-1), state: .available, values: ["total": 30]),
            MonitoringHistoryPoint(capturedAt: date, state: .available, values: ["total": .nan]),
        ]
        let points = ProcessorChartData.points(rows, core: nil)
        XCTAssertEqual(points.count, 2); XCTAssertNotEqual(points[0].segment, points[1].segment)
    }
}

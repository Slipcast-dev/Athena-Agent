import AppKit
import Foundation
import SwiftUI
import XCTest
import EcosystemLocalIPC
@testable import MacAssistantCore
@testable import MacAssistant

private final class NetworkSessionClock: @unchecked Sendable {
    private let lock = NSLock()
    private var seconds: Double = 0
    var clock: MonitoringClock { MonitoringClock { self.now() } }
    func now() -> MonitoringInstant {
        lock.lock(); defer { lock.unlock() }
        return MonitoringInstant(monotonic: seconds, date: Date(timeIntervalSince1970: seconds + 1_700_000_000))
    }
    func advance(_ value: Double) { lock.lock(); seconds += value; lock.unlock() }
}

private actor NetworkSessionSleeper {
    private let clock: NetworkSessionClock
    private let maximum: Int
    private var calls = 0
    init(clock: NetworkSessionClock, maximum: Int = 8) { self.clock = clock; self.maximum = maximum }
    func sleep(_ seconds: Double) throws {
        calls += 1; clock.advance(seconds)
        if calls >= maximum { throw CancellationError() }
    }
}

private actor NetworkSessionProvider: LiveMonitoringProviding {
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
        guard groups == [.network] else { throw LocalRuntimeFailure.invalidRequest }
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
        XCTAssertEqual(query.group, .network)
        calls.append("history.\(query.windowSeconds)"); return []
    }
}

private actor NetworkBlockingSleep {
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
final class NetworkViewModelTests: XCTestCase {
    func testVisibleSessionRenewsAndClosesLeaseWithoutRealSleeps() async {
        let clock = NetworkSessionClock(), provider = NetworkSessionProvider()
        let sleeper = NetworkSessionSleeper(clock: clock)
        let model = NetworkViewModel(provider: provider, clock: clock.clock, sleep: { try await sleeper.sleep($0) })
        await model.runWhileVisible()
        let calls = await provider.calls
        XCTAssertEqual(calls.filter { $0 == "subscribe" }.count, 1)
        XCTAssertEqual(calls.filter { $0 == "renew" }.count, 1)
        XCTAssertEqual(calls.last, "unsubscribe")
        XCTAssertEqual(calls.filter { $0 == "history.60" }.count, 8)
    }
    func testCancelledSessionDoesNotSubscribe() async {
        let provider = NetworkSessionProvider()
        let model = NetworkViewModel(provider: provider)
        let task = Task { withUnsafeCurrentTask { $0?.cancel() }; await model.runWhileVisible() }
        await task.value
        let calls = await provider.calls; XCTAssertTrue(calls.isEmpty)
    }
    func testCancellingVisibleViewReleasesItsActualLease() async {
        let provider = NetworkSessionProvider(), sleeper = NetworkBlockingSleep()
        let model = NetworkViewModel(provider: provider, sleep: { await sleeper.sleep($0) })
        let task = Task { await model.runWhileVisible() }
        await sleeper.waitUntilSleeping()
        task.cancel(); await sleeper.release(); await task.value
        let calls = await provider.calls
        XCTAssertEqual(calls.filter { $0 == "subscribe" }.count, 1)
        XCTAssertEqual(calls.filter { $0 == "unsubscribe" }.count, 1)
        XCTAssertEqual(calls.last, "unsubscribe")
    }
    func testExpiredLeaseCreatesNewSubscriptionAndCleansBoth() async {
        let clock = NetworkSessionClock(), provider = NetworkSessionProvider(failRenew: true)
        let sleeper = NetworkSessionSleeper(clock: clock, maximum: 9)
        let model = NetworkViewModel(provider: provider, clock: clock.clock, sleep: { try await sleeper.sleep($0) })
        await model.runWhileVisible()
        let calls = await provider.calls
        XCTAssertEqual(calls.filter { $0 == "subscribe" }.count, 2)
        XCTAssertEqual(calls.filter { $0 == "unsubscribe" }.count, 2)
        XCTAssertNil(model.runtimeError)
    }
    func testPersistentStopDoesNotSubscribeAndExplicitResumeCanBeObserved() async {
        let clock = NetworkSessionClock(), provider = NetworkSessionProvider(suspended: true)
        let sleeper = NetworkSessionSleeper(clock: clock, maximum: 3)
        let model = NetworkViewModel(provider: provider, clock: clock.clock, sleep: { try await sleeper.sleep($0) })
        await model.runWhileVisible()
        let calls = await provider.calls
        XCTAssertFalse(calls.contains("subscribe")); XCTAssertTrue(model.suspended)
        let resumed = NetworkSessionProvider(suspendedFirst: true)
        let secondSleep = NetworkSessionSleeper(clock: clock, maximum: 3)
        let second = NetworkViewModel(provider: resumed, clock: clock.clock, sleep: { try await secondSleep.sleep($0) })
        await second.runWhileVisible()
        let resumedCalls = await resumed.calls
        XCTAssertEqual(resumedCalls.filter { $0 == "subscribe" }.count, 1)
        XCTAssertFalse(second.suspended)
    }
    func testHistoryRangeDoesNotChangeRequestedChannels() async {
        let clock = NetworkSessionClock(), provider = NetworkSessionProvider()
        let sleeper = NetworkSessionSleeper(clock: clock, maximum: 2)
        let model = NetworkViewModel(provider: provider, clock: clock.clock, sleep: { try await sleeper.sleep($0) })
        model.historyWindow = .fifteenMinutes
        await model.runWhileVisible()
        let calls = await provider.calls; XCTAssertTrue(calls.contains("history.900"))
        model.selectedInterface = "missing"
        model.accept(snapshot: MonitoringSnapshot(suspended: false, samples: []), history: [])
        XCTAssertEqual(model.selectedInterface, "")
    }
}

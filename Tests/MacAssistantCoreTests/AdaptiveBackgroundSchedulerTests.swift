import XCTest
@testable import MacAssistantCore

private actor BackgroundProbe {
    var ticks = 0
    var seconds: TimeInterval?
    var gate: CheckedContinuation<Void, Never>?
    var blockFirst = false
    init(seconds: TimeInterval? = nil, blockFirst: Bool = false) { self.seconds = seconds; self.blockFirst = blockFirst }
    func tick() async {
        ticks += 1
        if blockFirst && ticks == 1 { await withCheckedContinuation { gate = $0 } }
    }
    func delay() -> TimeInterval? { seconds }
    func release() { gate?.resume(); gate = nil }
}

final class AdaptiveBackgroundSchedulerTests: XCTestCase {
    private func wait(_ probe: BackgroundProbe, count: Int) async throws {
        for _ in 0..<100 {
            if await probe.ticks >= count { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("Scheduler lost wake")
    }
    func testIdleHasNoPeriodicTicksAndStopPreventsNewWork() async throws {
        let probe = BackgroundProbe()
        let scheduler = AdaptiveBackgroundScheduler(tick: { await probe.tick() }, delay: { await probe.delay() })
        await scheduler.start(); try await wait(probe, count: 1)
        try await Task.sleep(for: .milliseconds(100))
        let idle = await probe.ticks; XCTAssertEqual(idle, 1)
        await scheduler.wake(); try await wait(probe, count: 2)
        await scheduler.stop(); await scheduler.wake()
        try await Task.sleep(for: .milliseconds(20))
        let stopped = await probe.ticks; XCTAssertEqual(stopped, 2)
    }
    func testWakeInterruptsLongDelay() async throws {
        let probe = BackgroundProbe(seconds: 3600)
        let scheduler = AdaptiveBackgroundScheduler(tick: { await probe.tick() }, delay: { await probe.delay() })
        await scheduler.start(); try await wait(probe, count: 1)
        await scheduler.wake(); try await wait(probe, count: 2)
        await scheduler.stop()
    }
    func testWakeDuringTickIsNotLostBeforeIdleWait() async throws {
        let probe = BackgroundProbe(blockFirst: true)
        let scheduler = AdaptiveBackgroundScheduler(tick: { await probe.tick() }, delay: { await probe.delay() })
        await scheduler.start(); try await wait(probe, count: 1)
        await scheduler.wake(); await probe.release()
        try await wait(probe, count: 2)
        await scheduler.stop()
    }
}

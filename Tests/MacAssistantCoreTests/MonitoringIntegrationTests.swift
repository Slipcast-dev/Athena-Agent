import XCTest
@testable import MacAssistantCore
@testable import MacAssistant

private actor IntegratedCollector: MonitoringCollecting {
    nonisolated let group: MonitoringGroup
    private(set) var calls = 0
    init(_ group: MonitoringGroup) { self.group = group }
    func collect(reset: Bool) -> MonitoringCollection {
        calls += 1
        let payload: MonitoringPayload
        switch group {
        case .cpu: payload = .cpu(.init(totalPercent: .init(20)))
        case .memory: payload = .memory(.init(totalBytes: .init(1000), usedBytes: .init(400), availableBytes: .init(600)))
        case .network: payload = .network([])
        case .processes: payload = .processes([])
        case .disk: payload = .disk([])
        case .battery: payload = .battery(.init(present: .init(false)))
        case .applications: payload = .applications(.init(capturedAt: Date(timeIntervalSince1970: 1000), applications: [], roots: [], discoveredApplications: 0, visitedEntries: 0, enumerationComplete: true, limitReached: false))
        }
        return .init(payload: payload)
    }
}

/// Управляемый await имитирует видимое окно без настоящего секундного таймера.
private actor IntegratedWindowGate {
    private var waiting: CheckedContinuation<Void, Never>?
    private var watchers: [CheckedContinuation<Void, Never>] = []
    func sleep(_ seconds: TimeInterval) async {
        await withCheckedContinuation { waiting = $0; watchers.forEach { $0.resume() }; watchers.removeAll() }
    }
    func started() async {
        if waiting != nil { return }
        await withCheckedContinuation { watchers.append($0) }
    }
    func release() { waiting?.resume(); waiting = nil }
}

@MainActor
final class MonitoringIntegrationTests: XCTestCase {
    func testFiveScreensAndSecondCPUWindowShareCollectorsAndReleaseEveryLease() async throws {
        let sources = MonitoringGroup.allCases.map(IntegratedCollector.init)
        let instant = MonitoringInstant(monotonic: 0, date: Date(timeIntervalSince1970: 1000))
        let coordinator = MonitoringCoordinator(collectors: sources, clock: MonitoringClock { instant }, automaticSampling: false)
        let gates = (0..<6).map { _ in IntegratedWindowGate() }
        let cpu = ProcessorViewModel(provider: coordinator, sleep: { await gates[0].sleep($0) })
        let network = NetworkViewModel(provider: coordinator, sleep: { await gates[1].sleep($0) })
        let disk = DiskViewModel(provider: coordinator, sleep: { await gates[2].sleep($0) })
        let memory = MemoryViewModel(provider: coordinator, sleep: { await gates[3].sleep($0) })
        let battery = BatteryViewModel(provider: coordinator, sleep: { await gates[4].sleep($0) })
        let secondCPU = ProcessorViewModel(provider: coordinator, sleep: { await gates[5].sleep($0) })
        let jobs = [Task { await cpu.runWhileVisible() }, Task { await network.runWhileVisible() },
                    Task { await disk.runWhileVisible() }, Task { await memory.runWhileVisible() },
                    Task { await battery.runWhileVisible() }, Task { await secondCPU.runWhileVisible() }]
        for gate in gates { await gate.started() }
        await coordinator.waitForCollections()
        for source in sources {
            let count = await source.calls
            XCTAssertEqual(count, 1, "One collector per channel regardless of window count")
        }
        var snapshot = await coordinator.snapshot()
        XCTAssertTrue(snapshot.samples.allSatisfy { $0.state == .available && !$0.stale })
        jobs[0].cancel(); await gates[0].release(); await jobs[0].value
        snapshot = await coordinator.snapshot()
        XCTAssertFalse(try XCTUnwrap(snapshot.samples.first { $0.group == .cpu }).stale, "The second CPU window keeps the shared channel alive")
        for index in 1..<jobs.count { jobs[index].cancel(); await gates[index].release() }
        for job in jobs { await job.value }
        snapshot = await coordinator.snapshot()
        XCTAssertTrue(snapshot.samples.allSatisfy(\.stale), "Leaving all screens must release all seven channels")
        await coordinator.shutdown()
    }

    func testLegacySelectionsAndKeyboardTraversalReachOnlyNewMenu() {
        XCTAssertEqual(AppSection.restored(from: "dashboard"), .processor)
        XCTAssertEqual(AppSection.restored(from: "storage"), .disk)
        XCTAssertEqual(AppSection.restored(from: "agents"), .settings)
        for section in AppSection.allCases { XCTAssertEqual(AppSection.restored(from: section.rawValue), section) }
        var section: AppSection? = .processor
        var visited: [AppSection] = [.processor]
        for _ in 1..<AppSection.allCases.count {
            section = SidebarView.destination(from: section, direction: .down)
            if let section { visited.append(section) }
        }
        XCTAssertEqual(visited, [.processor, .network, .disk, .memory, .battery, .diagnostics, .settings])
        XCTAssertNil(AppSection(rawValue: "dashboard")); XCTAssertNil(AppSection(rawValue: "storage"))
    }
}

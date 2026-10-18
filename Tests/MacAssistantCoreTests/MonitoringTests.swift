import XCTest
@testable import MacAssistantCore
import EcosystemLocalIPC
import EcosystemRuntimeSupport
import EcosystemContracts

final class MonitoringTests: XCTestCase {
    func metrics(cpu: Double? = 20, pressure: MemoryPressure? = nil, at: Date = Date()) -> SystemMetrics {
        SystemMetrics(capturedAt: at, cpuUsagePercent: cpu, totalMemoryBytes: 1000, usedMemoryBytes: 999,
            availableMemoryBytes: 1, memoryPressure: pressure, totalStorageBytes: 1000, availableStorageBytes: 500)
    }
    func directory() throws -> URL {
        let url = URL(fileURLWithPath: "/private/tmp", isDirectory: true).appendingPathComponent("athena-e5-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]); return url
    }
    func testFreshnessAndMissingCPUDoNotClaimCompletedMeasurement() throws {
        let now = Date()
        let warming = metrics(cpu: nil, at: now)
        XCTAssertEqual(warming.quality(now: now).cpu, .warmingUp)
        XCTAssertFalse(warming.quality(now: now).complete)
        XCTAssertEqual(warming.quality(now: now).memoryPressure, .unsupported)
        XCTAssertTrue(warming.quality(now: now.addingTimeInterval(121)).stale)
        XCTAssertTrue(warming.quality(now: now.addingTimeInterval(-10)).stale)
        let result = try AthenaPublicResult.result(capability: "system.get_metrics", data: LocalWire.encode(warming), now: now)
        XCTAssertTrue(result["capturedAt"] is String)
        XCTAssertEqual((result["quality"] as? [String: Any])?["cpu"] as? String, "warmingUp")
    }
    func testNoRAMPercentAlertWithoutPressureAndUnavailableBreaksWindow() {
        var rule = MonitorRule(); rule.metric = .memoryPressure; rule.warning = 1; rule.critical = 2; rule.recovery = 0
        let now = Date()
        XCTAssertNil(MonitorEvaluator.value(metrics(), metric: .memoryPressure, now: now))
        let (state, event) = MonitorEvaluator.step(rule: rule, state: .init(), value: nil, now: now)
        XCTAssertEqual(state.status, .unavailable); XCTAssertEqual(event?.status, .unavailable)
        XCTAssertFalse(DiagnosticFindingFactory.makeFindings(for: metrics(), thresholds: .init()).contains { $0.severity != .info })
    }
    func testSustainedCPUHysteresisEscalationAndRecovery() {
        var rule = MonitorRule(); rule.intervalSeconds = 60
        var state = MonitorState(); let now = Date(); var tick = 0
        func sample(_ value: Double) -> MonitorEvent? {
            tick += 1; let (next, event) = MonitorEvaluator.step(rule: rule, state: state, value: value, now: now.addingTimeInterval(Double(tick * 60))); state = next; return event
        }
        _ = sample(96); _ = sample(10); _ = sample(10); XCTAssertEqual(state.status, .normal)
        _ = sample(85); _ = sample(85); let warned = sample(85); XCTAssertTrue(warned?.notificationEligible == true)
        XCTAssertEqual(state.status, .warning)
        _ = sample(99); _ = sample(99); let escalated = sample(99)
        XCTAssertEqual(state.status, .critical); XCTAssertTrue(escalated?.notificationEligible == true)
        _ = sample(79); _ = sample(74); XCTAssertNotEqual(state.status, .recovered)
        _ = sample(74); let recovered = sample(74)
        XCTAssertEqual(state.status, .recovered); XCTAssertTrue(recovered?.notificationEligible == true)
    }
    func testCooldownAndClockGapDoNotReplayAlarmEveryTick() {
        var rule = MonitorRule(); rule.intervalSeconds = 60; rule.windowSamples = 2
        var state = MonitorState(); let now = Date()
        (state, _) = MonitorEvaluator.step(rule: rule, state: state, value: 90, now: now)
        let pair = MonitorEvaluator.step(rule: rule, state: state, value: 90, now: now.addingTimeInterval(60)); state = pair.0
        XCTAssertTrue(pair.1?.notificationEligible == true)
        let duplicate = MonitorEvaluator.step(rule: rule, state: state, value: 90, now: now.addingTimeInterval(120))
        XCTAssertNil(duplicate.1)
        let stale = MonitorEvaluator.step(rule: rule, state: state, value: 90, now: now.addingTimeInterval(1000))
        XCTAssertEqual(stale.0.status, .warmingUp); XCTAssertEqual(stale.0.samples.count, 1)
        let lost = MonitorEvaluator.step(rule: rule, state: state, value: nil, now: now.addingTimeInterval(120))
        XCTAssertEqual(lost.0.status, .unavailable); XCTAssertTrue(lost.0.samples.isEmpty)
    }
    func testMonitorConfigRejectsZeroWindowNaNAndRAMPercentThreshold() {
        var rule = MonitorRule(); rule.intervalSeconds = 59; XCTAssertThrowsError(try rule.validate())
        rule.intervalSeconds = 60; rule.windowSamples = 1; XCTAssertThrowsError(try rule.validate())
        rule.windowSamples = 3; rule.warning = .nan; XCTAssertThrowsError(try rule.validate())
        rule.warning = 80; rule.metric = .memoryPressure; XCTAssertThrowsError(try rule.validate())
    }
    func testPlansRequireGUIExpireAndDisableRevokesPendingAndLateSample() async throws {
        let dir = try directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let store = try MonitorStore(directory: dir); var rule = MonitorRule(); rule.metric = .storage; rule.critical = 90
        let entry = try await store.propose(rule); XCTAssertFalse(entry.enabled)
        let now = Date(); let plan = try await store.requestEnable(entry.id, now: now)
        do { _ = try await store.approve(plan.id, fingerprint: plan.fingerprint, role: .mcp, now: now); XCTFail("MCP approval") } catch { XCTAssertEqual(error as? LocalRuntimeFailure, .denied) }
        do { _ = try await store.approve(plan.id, fingerprint: plan.fingerprint, role: .gui, now: now.addingTimeInterval(301)); XCTFail("Expired approval") } catch { XCTAssertEqual(error as? LocalRuntimeFailure, .staleSnapshot) }
        _ = try await store.approve(plan.id, fingerprint: plan.fingerprint, role: .gui, now: now)
        do { _ = try await store.approve(plan.id, fingerprint: plan.fingerprint, role: .gui); XCTFail("Spent plan") } catch { XCTAssertEqual(error as? LocalRuntimeFailure, .staleSnapshot) }
        _ = try await store.requestEnable(entry.id)
        _ = try await store.disable(entry.id)
        try await store.record(id: entry.id, revision: entry.rule.fingerprint, metrics: metrics(), now: now)
        let final = try await store.entry(entry.id); XCTAssertNil(final.state.lastSampleAt)
        let pending = await store.pending(); XCTAssertTrue(pending.isEmpty)
    }
    func testStateAndCooldownSurviveReloadAndDueHonorsInterval() async throws {
        let dir = try directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let store = try MonitorStore(directory: dir); var rule = MonitorRule(); rule.metric = .storage; rule.critical = 90; rule.intervalSeconds = 60
        let entry = try await store.propose(rule); let now = Date()
        let plan = try await store.requestEnable(entry.id, now: now)
        _ = try await store.approve(plan.id, fingerprint: plan.fingerprint, role: .gui, now: now)
        try await store.record(id: entry.id, revision: plan.fingerprint, metrics: metrics(at: now), now: now)
        let fresh = try MonitorStore(directory: dir)
        let loaded = try await fresh.entry(entry.id); XCTAssertTrue(loaded.enabled); XCTAssertEqual(loaded.state.samples, [50])
        let early = await fresh.due(now: now.addingTimeInterval(59)); XCTAssertTrue(early.isEmpty)
        let due = await fresh.due(now: now.addingTimeInterval(60)); XCTAssertEqual(due.count, 1)
    }
    func testUnknownApprovalFieldsAndWorkerManagementAreRejected() async throws {
        let dir = try directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let store = try MonitorStore(directory: dir)
        let forged = LocalRPCRequest(domain: "athena", operation: "monitor.request_enable", payload: Data("{\"approved\":true}".utf8))
        do { _ = try await MonitorControl.handle(store: store, role: .mcp, request: forged); XCTFail("Forged approval") } catch { }
        XCTAssertEqual(Set(AthenaMCP.names).count, 22)
        XCTAssertFalse(AthenaMCP.names.contains("monitor.approve"))
    }
    func testCPUCounterResetAndOverflowDoNotGenerateFalseLoad() {
        XCTAssertNil(CPUUsageCalculator.usagePercent(previous: .init(user: 100, system: 100, idle: 100, nice: 0), current: .init(user: 99, system: 101, idle: 101, nice: 0)))
        let result = CPUUsageCalculator.usagePercent(previous: .init(user: 0, system: 0, idle: 0, nice: 0), current: .init(user: .max, system: .max, idle: .max, nice: .max))
        XCTAssertEqual(result, 75)
    }
    func testMissingCPUProducesPartialReportWithStructuredQuality() async throws {
        let source = WarmingSystem(metrics: metrics(cpu: nil))
        let report = try await SystemDiagnosticsService(systemInformation: source).runDiagnostics()
        XCTAssertEqual(report.status, .partial)
        let projected = try AthenaPublicResult.result(capability: "diagnostics.run", data: LocalWire.encode(report))
        XCTAssertEqual(projected["status"] as? String, "partial")
        XCTAssertEqual((projected["quality"] as? [String: Any])?["complete"] as? Bool, false)
    }
    func testMonitoringSamplerIsIndependentFromInteractiveCPURequests() async throws {
        let dir = try directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let store = try MonitorStore(directory: dir)
        let entry = try await store.propose(MonitorRule()); let plan = try await store.requestEnable(entry.id)
        _ = try await store.approve(plan.id, fingerprint: plan.fingerprint, role: .gui)
        let interactive = CountingSystem(cpu: 10), background = CountingSystem(cpu: 99)
        let queue = try DurableTaskQueue(directory: dir.appendingPathComponent("queue"), agentID: .athena)
        let work = try AthenaQueuedWork(queue: queue, grants: AthenaLocalGrants(directory: dir), system: interactive,
            diagnostics: BlockingDiagnostics(), storage: StorageAnalysisService(), monitors: store, monitorSystem: background)
        let task = try await work.submit(AthenaSubmission(capability: "system.get_metrics", job: AthenaJob(), key: "interactive"), role: .mcp)
        try await work.pollMonitors()
        for _ in 0..<100 {
            if try await queue.tasks().allSatisfy({ $0.status.isTerminal }) { break }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        let foregroundCount = await interactive.count, backgroundCount = await background.count
        XCTAssertEqual(foregroundCount, 1); XCTAssertEqual(backgroundCount, 1)
        let state = try await store.entry(entry.id); XCTAssertEqual(state.state.samples, [99])
        let saved = try await queue.task(task.id); XCTAssertEqual(saved?.status, .completed)
        await work.shutdown()
    }
    func testQueueCancellationStopsActualDiagnosticService() async throws {
        let dir = try directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let diagnostics = BlockingDiagnostics()
        let queue = try DurableTaskQueue(directory: dir.appendingPathComponent("queue"), agentID: .athena)
        let grants = try AthenaLocalGrants(directory: dir)
        let work = try AthenaQueuedWork(queue: queue, grants: grants, system: SystemInformationService(), diagnostics: diagnostics, storage: StorageAnalysisService(), monitors: MonitorStore(directory: dir))
        let service = AthenaRuntimeService(work: work, grants: grants)
        do { _ = try await service.handle(role: .worker, request: LocalRPCRequest(domain: "athena", operation: "monitor.list", payload: LocalWire.encode(MonitorRequest()))); XCTFail("Worker management") } catch { XCTAssertEqual(error as? LocalRuntimeFailure, .denied) }
        let task = try await work.submit(AthenaSubmission(capability: "diagnostics.run", job: AthenaJob(), key: "cancel-real-service"), role: .mcp)
        for _ in 0..<100 { if await diagnostics.started { break }; try await Task.sleep(nanoseconds: 5_000_000) }
        try await work.cancel(task.id, role: .mcp)
        for _ in 0..<100 { if try await queue.task(task.id)?.status.isTerminal == true { break }; try await Task.sleep(nanoseconds: 5_000_000) }
        let cancelled = await diagnostics.cancelled; XCTAssertTrue(cancelled)
        let saved = try await queue.task(task.id); XCTAssertEqual(saved?.status, .cancelled); XCTAssertNil(saved?.result)
        await work.shutdown()
    }
}
private actor BlockingDiagnostics: SystemDiagnosing {
    private(set) var started = false
    private(set) var cancelled = false
    func runDiagnostics() async throws -> DiagnosticReport {
        started = true
        do { try await Task.sleep(nanoseconds: 30_000_000_000) } catch { cancelled = true; throw error }
        throw CancellationError()
    }
}

private struct WarmingSystem: SystemInformationProviding {
    let metrics: SystemMetrics
    func systemInfo() async throws -> SystemInfo { SystemInfo(modelName: "Test", operatingSystemVersion: "Test", architecture: "arm64", physicalCPUCoreCount: 4, logicalCPUCoreCount: 4) }
    func systemMetrics() async throws -> SystemMetrics { metrics }
}

private actor CountingSystem: SystemInformationProviding {
    let cpu: Double
    private(set) var count = 0
    init(cpu: Double) { self.cpu = cpu }
    func systemInfo() async throws -> SystemInfo { SystemInfo(modelName: "Test", operatingSystemVersion: "Test", architecture: "arm64", physicalCPUCoreCount: 4, logicalCPUCoreCount: 4) }
    func systemMetrics() async throws -> SystemMetrics {
        count += 1
        return SystemMetrics(cpuUsagePercent: cpu, totalMemoryBytes: 1000, usedMemoryBytes: 999, availableMemoryBytes: 1, memoryPressure: nil, totalStorageBytes: 1000, availableStorageBytes: 500)
    }
}

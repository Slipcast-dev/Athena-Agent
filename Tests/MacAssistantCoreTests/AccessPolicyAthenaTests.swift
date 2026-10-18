import XCTest
@testable import MacAssistantCore
import EcosystemContracts
import EcosystemLocalIPC
import EcosystemRuntimeSupport

final class AccessPolicyAthenaTests: XCTestCase {
    struct Fixture {
        let directory: URL; let policy: LocalAccessPolicy; let work: AthenaQueuedWork
        let service: AthenaRuntimeService; let diagnostics: AccessBlockingDiagnostics; let monitors: MonitorStore
    }
    func fixture() throws -> Fixture {
        let directory = URL(fileURLWithPath: "/private/tmp").appendingPathComponent("athena-e6-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let policy = try LocalAccessPolicy(directory: directory, domain: "athena"), grants = try AthenaLocalGrants(directory: directory)
        let diagnostics = AccessBlockingDiagnostics(), monitors = try MonitorStore(directory: directory)
        let work = try AthenaQueuedWork(queue: DurableTaskQueue(directory: directory.appendingPathComponent("queue"), agentID: .athena), grants: grants, system: SystemInformationService(), diagnostics: diagnostics, storage: StorageAnalysisService(), monitors: monitors, policy: policy)
        return Fixture(directory: directory, policy: policy, work: work, service: AthenaRuntimeService(work: work, grants: grants), diagnostics: diagnostics, monitors: monitors)
    }
    func grant(_ f: Fixture, _ client: LocalMCPClient) async throws -> LocalAccessGrant {
        var draft = LocalAccessDraft(); draft.client = client; draft.capabilities = f.policy.capabilities
        let plan = try await f.policy.request(draft, client: client)
        return try await f.policy.approve(plan.id, fingerprint: plan.fingerprint, role: .gui)
    }
    func testDefaultDenyAndCrossClientTaskCannotExposeInternalRequest() async throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.directory) }
        let submission = AthenaSubmission(capability: "system.get_metrics", job: AthenaJob(), key: "metrics")
        do { _ = try await f.work.submit(submission, role: .mcp, clientID: .codex); XCTFail("Implicit grant") } catch { XCTAssertEqual(error as? LocalRuntimeFailure, .denied) }
        _ = try await grant(f, .codex); _ = try await grant(f, .deepseekHarness)
        let task = try await f.work.submit(submission, role: .mcp, clientID: .codex)
        for _ in 0..<100 { if try await f.work.queue.task(task.id)?.status.isTerminal == true { break }; try await Task.sleep(nanoseconds: 5_000_000) }
        let own = try await f.work.task(task.id, role: .mcp, clientID: .codex)
        XCTAssertTrue(own.request.isEmpty); XCTAssertTrue(own.resources.isEmpty); XCTAssertNil(own.lease)
        do { _ = try await f.work.task(task.id, role: .mcp, clientID: .deepseekHarness); XCTFail("Cross task") } catch { XCTAssertEqual(error as? LocalRuntimeFailure, .denied) }
        let request = try LocalRPCRequest(domain: "athena", operation: "access.status", payload: LocalWire.encode(LocalAccessRequest()))
        let data = try await f.service.handle(role: .mcp, clientID: .codex, request: request)
        let status = try LocalWire.decode(LocalAccessState.self, data); XCTAssertEqual(status.grants.map(\.draft.client), [.codex])
        await f.work.shutdown()
    }
    func testRevokeCancelsActualRunningServiceAndOldResultCannotRevive() async throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.directory) }
        let granted = try await grant(f, .codex)
        let task = try await f.work.submit(AthenaSubmission(capability: "diagnostics.run", job: AthenaJob(), key: "cancel-on-revoke"), role: .mcp, clientID: .codex)
        for _ in 0..<100 { if await f.diagnostics.started { break }; try await Task.sleep(nanoseconds: 5_000_000) }
        let started = await f.diagnostics.started; XCTAssertTrue(started)
        _ = try await f.service.handle(role: .gui, request: LocalRPCRequest(domain: "athena", operation: "access.revoke", payload: LocalWire.encode(LocalAccessRequest(grantID: granted.id))))
        for _ in 0..<100 { if try await f.work.queue.task(task.id)?.status.isTerminal == true { break }; try await Task.sleep(nanoseconds: 5_000_000) }
        let cancelled = await f.diagnostics.cancelled; XCTAssertTrue(cancelled)
        let final = try await f.work.queue.task(task.id); XCTAssertEqual(final?.status, .cancelled)
        _ = try await grant(f, .codex)
        do { _ = try await f.work.task(task.id, role: .mcp, clientID: .codex); XCTFail("Old result revived") } catch { XCTAssertEqual(error as? LocalRuntimeFailure, .denied) }
        await f.work.shutdown()
    }
    func testRevokedMonitorPlanCannotBeApprovedEvenByGUI() async throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.directory) }
        let granted = try await grant(f, .codex)
        let monitor = try await f.monitors.propose(MonitorRule())
        let requested = try await f.service.handle(role: .mcp, clientID: .codex, request: LocalRPCRequest(domain: "athena", operation: "monitor.request_enable", payload: LocalWire.encode(MonitorRequest(monitorID: monitor.id))))
        let plan = try LocalWire.decode(MonitorPlan.self, requested); XCTAssertNil(plan.accessTicket)
        let stored = await f.monitors.pending().first(where: { $0.id == plan.id }); XCTAssertEqual(stored?.accessTicket?.client, .codex)
        _ = try await f.service.handle(role: .gui, request: LocalRPCRequest(domain: "athena", operation: "access.revoke", payload: LocalWire.encode(LocalAccessRequest(grantID: granted.id))))
        do { _ = try await f.service.handle(role: .gui, request: LocalRPCRequest(domain: "athena", operation: "monitor.approve", payload: LocalWire.encode(MonitorRequest(planID: plan.id, fingerprint: plan.fingerprint)))); XCTFail("Revived monitor plan") } catch { XCTAssertEqual(error as? LocalRuntimeFailure, .denied) }
        let pendingData = try await f.service.handle(role: .gui, request: LocalRPCRequest(domain: "athena", operation: "monitor.pending", payload: LocalWire.encode(MonitorRequest())))
        XCTAssertTrue(try LocalWire.decode([MonitorPlan].self, pendingData).isEmpty)
        let entry = try await f.monitors.entry(monitor.id); XCTAssertFalse(entry.enabled)
        await f.work.shutdown()
    }
}
actor AccessBlockingDiagnostics: SystemDiagnosing {
    private(set) var started = false
    private(set) var cancelled = false
    func runDiagnostics() async throws -> DiagnosticReport {
        started = true
        do { try await Task.sleep(nanoseconds: 30_000_000_000) } catch { cancelled = true; throw error }
        throw CancellationError()
    }
}

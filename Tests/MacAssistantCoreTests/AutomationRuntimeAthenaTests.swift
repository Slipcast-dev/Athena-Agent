import XCTest
@testable import MacAssistantCore
import EcosystemContracts
import EcosystemLocalIPC
import EcosystemRuntimeSupport

/// Runtime проверяется через настоящий обработчик RPC и приватные журналы,
/// а системные уведомления заменены адаптером без диалогов разрешений.
final class AutomationRuntimeAthenaTests: XCTestCase {
    private struct Fixture {
        let directory: URL
        let policy: LocalAccessPolicy
        let work: AthenaQueuedWork
        let automation: LocalAutomationService
        let service: AthenaRuntimeService
    }
    private func fixture() throws -> Fixture {
        let directory = URL(fileURLWithPath: "/private/tmp").appendingPathComponent("athena-e7-rpc-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let policy = try LocalAccessPolicy(directory: directory, domain: "athena")
        let grants = try AthenaLocalGrants(directory: directory)
        let work = try AthenaQueuedWork(queue: DurableTaskQueue(directory: directory.appendingPathComponent("queue"), agentID: .athena), grants: grants, system: SystemInformationService(), diagnostics: AccessBlockingDiagnostics(), storage: StorageAnalysisService(), monitors: MonitorStore(directory: directory), policy: policy)
        let automation = try LocalAutomationService(directory: directory, domain: "athena", notifications: AthenaAutomationTestSink())
        return Fixture(directory: directory, policy: policy, work: work, automation: automation,
                       service: AthenaRuntimeService(work: work, grants: grants, automation: automation))
    }
    @discardableResult
    private func grant(_ fixture: Fixture, client: LocalMCPClient = .codex,
                       capabilities: [String] = ["events.read", "monitor.history"]) async throws -> LocalAccessGrant {
        var draft = LocalAccessDraft(); draft.client = client; draft.capabilities = capabilities
        let plan = try await fixture.policy.request(draft, client: client)
        return try await fixture.policy.approve(plan.id, fingerprint: plan.fingerprint, role: .gui)
    }
    private func call(_ fixture: Fixture, _ operation: String, payload: [String: Any] = [:],
                      role: LocalRole = .mcp, client: LocalMCPClient = .codex) async throws -> Data {
        try await fixture.service.handle(role: role, clientID: client,
            request: LocalRPCRequest(domain: "athena", operation: operation,
                                     payload: JSONSerialization.data(withJSONObject: payload)))
    }
    private func expect(_ failure: LocalRuntimeFailure, _ body: () async throws -> Void) async {
        do { try await body(); XCTFail("Ожидался отказ RPC") }
        catch { XCTAssertEqual(error as? LocalRuntimeFailure, failure) }
    }
    private func event(_ fixture: Fixture, capability: String = "monitor.history") async throws -> UUID {
        let id = UUID()
        try await fixture.automation.record(id: id, kind: "monitor.threshold", capability: capability,
                                            capturedAt: Date(), significant: true)
        return id
    }
    func testEmergencyControlIsGUIOnlyAndBlocksNativeSubmission() async throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.directory) }
        for operation in ["operations.emergency_status", "operations.emergency_stop", "operations.emergency_resume"] {
            for role in [LocalRole.mcp, .worker] {
                await expect(.denied) { _ = try await self.call(f, operation, role: role) }
            }
        }
        await expect(.invalidRequest) { _ = try await self.call(f, "operations.emergency_stop", payload: ["client": "gui"], role: .gui) }
        let stopped = try LocalWire.decode(QueueEmergencyStatus.self, await call(f, "operations.emergency_stop", role: .gui))
        XCTAssertTrue(stopped.stopped)
        do {
            _ = try await call(f, "work.submit", payload: ["capability": "system.get_info", "job": [:], "key": "stop-test"], role: .gui)
            XCTFail("Stopped runtime accepted a task")
        } catch { XCTAssertEqual(error as? QueueFailure, .emergencyStopped) }
        let resumed = try LocalWire.decode(QueueEmergencyStatus.self, await call(f, "operations.emergency_resume", role: .gui))
        XCTAssertFalse(resumed.stopped)
        _ = try await call(f, "work.submit", payload: ["capability": "system.get_info", "job": [:], "key": "resume-test"], role: .gui)
        await f.work.shutdown()
    }
    func testMCPCannotConfigureAutomationAndEventsRequireSeparateCapabilities() async throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.directory) }
        for operation in ["automation.configure", "automation.request_notifications", "automation.login_configure", "automation.login_status"] {
            await expect(.denied) { _ = try await self.call(f, operation) }
        }
        _ = try await event(f)
        await expect(.denied) { _ = try await self.call(f, "events.list") }
        try await grant(f, capabilities: ["events.read"])
        let hidden = try LocalWire.decode([LocalInboxDelivery].self, await call(f, "events.list"))
        XCTAssertTrue(hidden.isEmpty)
        try await grant(f)
        let visible = try LocalWire.decode([LocalInboxDelivery].self, await call(f, "events.claim"))
        XCTAssertEqual(visible.count, 1); XCTAssertNotNil(visible.first?.token)
        XCTAssertEqual(visible.first?.state, .claimed)
        XCTAssertFalse(visible.first?.event.summary.contains("/") ?? true)
        await f.work.shutdown()
    }
    func testWrongClientAndRegrantCannotAcknowledgeOriginalLease() async throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.directory) }
        let granted = try await grant(f)
        try await grant(f, client: .deepseekHarness)
        let id = try await event(f)
        let claims = try LocalWire.decode([LocalInboxDelivery].self, await call(f, "events.claim"))
        let token = try XCTUnwrap(claims.first?.token)
        let payload = ["eventID": id.uuidString, "token": token.uuidString]
        await expect(.denied) { _ = try await self.call(f, "events.ack", payload: payload, client: .deepseekHarness) }
        _ = try await f.policy.revoke(granted.id, role: .gui)
        await expect(.denied) { _ = try await self.call(f, "events.ack", payload: payload) }
        try await grant(f)
        await expect(.denied) { _ = try await self.call(f, "events.ack", payload: payload) }
        let harness = try LocalWire.decode([LocalInboxDelivery].self, await call(f, "events.claim", client: .deepseekHarness))
        let harnessToken = try XCTUnwrap(harness.first?.token)
        _ = try await call(f, "events.ack", payload: ["eventID": id.uuidString, "token": harnessToken.uuidString], client: .deepseekHarness)
        let acknowledged = try LocalWire.decode([LocalInboxDelivery].self, await call(f, "events.list", client: .deepseekHarness))
        XCTAssertEqual(acknowledged.first?.state, .acked)
        await f.work.shutdown()
    }
    func testGUIListsNewestTwentyWithoutDeliveryTokens() async throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.directory) }
        var ids: [UUID] = []
        for _ in 0..<25 { ids.append(try await event(f)) }
        try await grant(f)
        _ = try await call(f, "events.claim")
        let rows = try LocalWire.decode([LocalInboxDelivery].self,
            await call(f, "events.list", payload: ["limit": 20], role: .gui))
        XCTAssertEqual(rows.map { $0.event.id }, Array(ids.suffix(20).reversed()))
        XCTAssertTrue(rows.allSatisfy { $0.token == nil && $0.leaseExpiresAt == nil })
        await f.work.shutdown()
    }
    func testRPCRejectsUnknownKeysWrongTypesAndLimits() async throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.directory) }
        try await grant(f)
        for payload: [String: Any] in [["client": "deepseekHarness"], ["limit": "50"], ["limit": 0], ["limit": 51]] {
            await expect(.invalidRequest) { _ = try await self.call(f, "events.list", payload: payload) }
        }
        for payload: [String: Any] in [["leaseSeconds": 29], ["leaseSeconds": 301], ["leaseSeconds": "120"]] {
            await expect(.invalidRequest) { _ = try await self.call(f, "events.claim", payload: payload) }
        }
        await expect(.invalidRequest) { _ = try await self.call(f, "automation.configure", payload: ["paused": "yes"], role: .gui) }
        await expect(.invalidRequest) { _ = try await self.call(f, "events.ack", payload: ["eventID": "invalid", "token": UUID().uuidString]) }
        await expect(.denied) { _ = try await self.call(f, "events.list", role: .worker) }
        await f.work.shutdown()
    }
}

private actor AthenaAutomationTestSink: LocalNotificationSending {
    func authorization() -> String { "unavailable" }
    func requestAuthorization() -> String { "unavailable" }
    func send(id: UUID, title: String, body: String) throws { throw LocalRuntimeFailure.denied }
}

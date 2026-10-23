import Foundation
import XCTest
import EcosystemLocalIPC
import EcosystemRuntimeSupport
@testable import MacAssistantCore

final class LiveMonitoringRuntimeTests: XCTestCase {
    private struct Fixture {
        let service: AthenaRuntimeService
        let coordinator: MonitoringCoordinator
        let work: AthenaQueuedWork
    }

    /// Все persistent stores принадлежат временному каталогу теста; ни один
    /// рабочий профиль или клиентский grant пользователя не открывается.
    private func withFixture(_ body: (Fixture) async throws -> Void) async throws {
        let directory = URL(fileURLWithPath: "/private/tmp").appendingPathComponent("athena-live-tests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let grants = try AthenaLocalGrants(directory: directory)
        let queue = try DurableTaskQueue(directory: directory.appendingPathComponent("queue"), agentID: .athena)
        let system = SystemInformationService()
        let work = try AthenaQueuedWork(queue: queue, grants: grants, system: system,
                                       diagnostics: SystemDiagnosticsService(systemInformation: system), storage: StorageAnalysisService())
        let coordinator = MonitoringCoordinator.makeLive()
        let fixture = Fixture(service: AthenaRuntimeService(work: work, grants: grants, liveMonitoring: coordinator),
                              coordinator: coordinator, work: work)
        do { try await body(fixture) }
        catch {
            await coordinator.shutdown(); await coordinator.waitForCollections(); await work.shutdown()
            try? FileManager.default.removeItem(at: directory); throw error
        }
        await coordinator.shutdown(); await coordinator.waitForCollections(); await work.shutdown()
        try FileManager.default.removeItem(at: directory)
    }

    private func call(_ fixture: Fixture, _ operation: String, _ payload: String = "{}", role: LocalRole = .gui) async throws -> Data {
        try await fixture.service.handle(role: role, request: LocalRPCRequest(domain: "athena", operation: operation, payload: Data(payload.utf8)))
    }

    func testAllNewEndpointsDenyMCPAndWorkerBeforePayloadParsing() async throws {
        try await withFixture { fixture in
            for operation in ["subscribe", "renew", "unsubscribe", "snapshot", "history", "refreshApplications"] {
                for role in [LocalRole.mcp, .worker] {
                    do { _ = try await call(fixture, "monitoring." + operation, "invalid-json", role: role); XCTFail("Role bypass") }
                    catch { XCTAssertEqual(error as? LocalRuntimeFailure, .denied) }
                }
            }
            XCTAssertFalse(AthenaMCP.names.contains { $0.hasPrefix("monitoring.") })
            let tasks = try await fixture.work.queue.tasks(limit: 100); XCTAssertTrue(tasks.isEmpty)
        }
    }

    func testStrictSchemaAndHistoryRequestBounds() async throws {
        try await withFixture { fixture in
            let invalid: [(String, String)] = [
                ("subscribe", #"{"groups":[]}"#),
                ("snapshot", "invalid-json"),
                ("subscribe", #"{"groups":["shell"]}"#),
                ("subscribe", #"{"groups":["cpu"],"role":"gui"}"#),
                ("snapshot", #"{"extra":true}"#),
                ("refreshApplications", #"{"extra":true}"#),
                ("history", #"{"group":"cpu","windowSeconds":3600,"maximumPoints":120}"#),
                ("history", #"{"group":"cpu","windowSeconds":60,"maximumPoints":121}"#),
                ("history", #"{"group":"cpu","windowSeconds":60,"maximumPoints":1}"#),
                ("renew", #"{"id":"not-a-uuid"}"#),
                ("snapshot", String(repeating: " ", count: 4097))
            ]
            for (operation, payload) in invalid {
                do { _ = try await call(fixture, "monitoring." + operation, payload); XCTFail("Invalid request accepted") }
                catch { XCTAssertEqual(error as? LocalRuntimeFailure, .invalidRequest) }
            }
        }
    }

    func testRealBasicCollectorsAndRepeatedRPCReadsCreateNoDurableTasks() async throws {
        try await withFixture { fixture in
            let data = try await call(fixture, "monitoring.subscribe", #"{"groups":["cpu","memory","disk"]}"#)
            let lease = try LocalWire.decode(MonitoringLease.self, data)
            await fixture.coordinator.waitForCollections()
            for _ in 0..<30 {
                let bytes = try await call(fixture, "monitoring.snapshot")
                XCTAssertLessThanOrEqual(bytes.count, LiveMonitoringControl.maximumResponseBytes)
                let snapshot = try LocalWire.decode(MonitoringSnapshot.self, bytes)
                let memory = snapshot.samples.first { $0.group == .memory }!
                XCTAssertEqual(memory.state, .available)
                guard case .memory(let metrics) = memory.payload else { return XCTFail("Missing real memory") }
                XCTAssertGreaterThan(metrics.totalBytes.value ?? 0, 0)
            }
            let tasks = try await fixture.work.queue.tasks(limit: 100); XCTAssertTrue(tasks.isEmpty)
            _ = try await call(fixture, "monitoring.unsubscribe", #"{"id":"\#(lease.id.uuidString)"}"#)
            let snapshot = try LocalWire.decode(MonitoringSnapshot.self, await call(fixture, "monitoring.snapshot"))
            XCTAssertTrue(snapshot.samples.allSatisfy(\.stale))
        }
    }

    func testEmergencyStopBlocksSamplingAndResumeRequiresNewLease() async throws {
        try await withFixture { fixture in
            let lease = try LocalWire.decode(MonitoringLease.self, await call(fixture, "monitoring.subscribe", #"{"groups":["cpu"]}"#))
            await fixture.coordinator.waitForCollections()
            _ = try await call(fixture, "operations.emergency_stop")
            let stopped = try LocalWire.decode(MonitoringSnapshot.self, await call(fixture, "monitoring.snapshot"))
            XCTAssertTrue(stopped.suspended); XCTAssertTrue(stopped.samples.allSatisfy(\.stale))
            do { _ = try await call(fixture, "monitoring.subscribe", #"{"groups":["cpu"]}"#); XCTFail("Emergency latch bypass") }
            catch { XCTAssertEqual(error as? LocalRuntimeFailure, .busy) }
            _ = try await call(fixture, "operations.emergency_resume")
            do { _ = try await call(fixture, "monitoring.renew", #"{"id":"\#(lease.id.uuidString)"}"#); XCTFail("Old lease revived") }
            catch { XCTAssertEqual(error as? LocalRuntimeFailure, .denied) }
            let resumed = try LocalWire.decode(MonitoringSnapshot.self, await call(fixture, "monitoring.snapshot"))
            XCTAssertFalse(resumed.suspended); XCTAssertTrue(resumed.samples.allSatisfy(\.stale))
            _ = try await call(fixture, "monitoring.subscribe", #"{"groups":["cpu"]}"#)
        }
    }

    @MainActor
    func testUnavailableContainerDoesNotStartRealMonitoring() async throws {
        let container = AppContainer(services: .unavailable)
        do { _ = try await container.services.liveMonitoring.subscribe(groups: [.cpu]); XCTFail("Implicit live sampler") }
        catch { XCTAssertEqual(error as? LocalRuntimeFailure, .unavailable) }
    }
}

import Foundation
import XCTest
import EcosystemLocalIPC
import EcosystemRuntimeSupport
@testable import MacAssistantCore

/// Реальные приватные документы и inbox; sink не вызывает macOS permissions.
/// Сериализованная история моделирует накопленный до запуска runtime backlog.
private actor BacklogNotificationSink: LocalNotificationSending {
    private var delivered: [UUID] = []
    func authorization() -> String { "authorized" }
    func requestAuthorization() -> String { "authorized" }
    func send(id: UUID, title: String, body: String) { delivered.append(id) }
    func sent() -> [UUID] { delivered }
}

final class MonitorBacklogReplayTests: XCTestCase {
    private struct HistoryDocument: Codable {
        var version = 1
        var entries: [MonitorEntry]
        var plans: [MonitorPlan] = []
        var history: [MonitorEvent]
    }
    private struct AutomationDocument: Codable {
        var version = 1
        var settings: LocalAutomationSettings
        var notified: [UUID] = []
        var nextNotificationAt: Date? = nil
    }
    private struct Fixture {
        let directory: URL
        let source: [MonitorEvent]
        let sink: BacklogNotificationSink
    }
    private func fixture(count: Int = 251, oldEvents: Bool = false) throws -> Fixture {
        let directory = URL(fileURLWithPath: "/private/tmp/athena-backlog-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let now = Date()
        var settings = LocalAutomationSettings()
        settings.createdAt = now.addingTimeInterval(-7200)
        settings.notificationsEnabled = true
        let rule = MonitorRule()
        let rows = (0..<count).map { index in
            MonitorEvent(id: UUID(), monitorID: rule.id,
                capturedAt: now.addingTimeInterval(oldEvents && index < 2 ? (index == 0 ? -7300 : -4000) : Double(index - count - 5)),
                previous: .normal, status: .warning, value: 85,
                notificationEligible: oldEvents ? index < 3 : index == 0)
        }
        try write(AutomationDocument(settings: settings), to: directory.appendingPathComponent("automation-v1.json"))
        try write(HistoryDocument(entries: [MonitorEntry(rule: rule)], history: rows), to: directory.appendingPathComponent("monitors-v1.json"))
        return Fixture(directory: directory, source: rows, sink: BacklogNotificationSink())
    }
    private func write<T: Encodable>(_ value: T, to file: URL) throws {
        try JSONEncoder().encode(value).write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
    /// Каждый вызов заново открывает все durable stores и queue owner. Никакого
    /// общего in-memory cursor между фазами восстановления не сохраняется.
    private struct Runtime {
        let monitors: MonitorStore
        let automation: LocalAutomationService
        let work: AthenaQueuedWork
        let service: AthenaRuntimeService
    }
    private func runtime(_ f: Fixture) throws -> Runtime {
        let monitors = try MonitorStore(directory: f.directory)
        let automation = try LocalAutomationService(directory: f.directory, domain: "athena", notifications: f.sink)
        let grants = try AthenaLocalGrants(directory: f.directory)
        let queue = try DurableTaskQueue(directory: f.directory.appendingPathComponent("queue"), agentID: .athena)
        let system = SystemInformationService()
        let work = try AthenaQueuedWork(queue: queue, grants: grants, system: system,
            diagnostics: SystemDiagnosticsService(systemInformation: system), storage: StorageAnalysisService(), monitors: monitors)
        return Runtime(monitors: monitors, automation: automation, work: work,
            service: AthenaRuntimeService(work: work, grants: grants, automation: automation))
    }
    private func replay(_ f: Fixture, ticks: Int = 1) async throws -> [LocalInboxEvent] {
        let live = try runtime(f)
        for _ in 0..<ticks { await live.service.tick() }
        let events = try await live.automation.inbox.events()
        await live.work.shutdown()
        return events
    }
    func testPartialFailureRetriesWithoutEnabledMonitorOrDuplicateEvents() async throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.directory) }
        let live = try runtime(f)
        // Часть партии уже committed до сбоя. Blocker создаётся только в нашем
        // tmp-профиле, не отзывая права macOS и не трогая пользовательские файлы.
        for event in f.source.suffix(120) {
            try await live.automation.record(id: event.id, kind: "monitor.warning", capability: "monitor.history", capturedAt: event.capturedAt, significant: event.notificationEligible)
        }
        let inbox = f.directory.appendingPathComponent("event-inbox-v1.json")
        let backup = f.directory.appendingPathComponent("saved-inbox.json")
        try FileManager.default.moveItem(at: inbox, to: backup)
        try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: false)
        await live.service.tick()
        let partial = try await live.automation.inbox.events()
        XCTAssertEqual(partial.count, 120)
        let retry = await live.service.nextBackgroundDelay(); XCTAssertEqual(retry, 5)
        try FileManager.default.removeItem(at: inbox)
        try FileManager.default.moveItem(at: backup, to: inbox)
        await live.service.tick(); await live.service.tick()
        let restored = try await live.automation.inbox.events()
        XCTAssertEqual(restored.count, 251); XCTAssertEqual(Set(restored.map(\.id)), Set(f.source.map(\.id)))
        let delay = await live.service.nextBackgroundDelay(); XCTAssertNil(delay)
        let sent = await f.sink.sent(); XCTAssertEqual(sent, [f.source[0].id])
        await live.work.shutdown()
    }
    func testDeliverySnapshotIsBoundedAndNotShiftedByNewHistory() async throws {
        let f = try fixture(count: 1000); defer { try? FileManager.default.removeItem(at: f.directory) }
        let store = try MonitorStore(directory: f.directory)
        let captured = await store.historyForDelivery()
        let entries = await store.entries()
        let entry = try XCTUnwrap(entries.first)
        var rule = entry.rule
        rule.metric = .storage; rule.windowSamples = 2; rule.warning = 40; rule.critical = 45; rule.recovery = 30
        let fresh = try await store.propose(rule)
        let plan = try await store.requestEnable(fresh.id)
        _ = try await store.approve(plan.id, fingerprint: plan.fingerprint, role: .gui)
        let now = Date()
        let metrics = SystemMetrics(capturedAt: now, cpuUsagePercent: 20, totalMemoryBytes: 1000,
            usedMemoryBytes: 500, availableMemoryBytes: 500, memoryPressure: nil, totalStorageBytes: 1000, availableStorageBytes: 500)
        try await store.record(id: fresh.id, revision: plan.fingerprint, metrics: metrics, now: now)
        try await store.record(id: fresh.id, revision: plan.fingerprint, metrics: metrics, now: now)
        let updated = await store.historyForDelivery()
        XCTAssertEqual(captured.count, 1000); XCTAssertEqual(updated.count, 1000)
        XCTAssertEqual(captured.map(\.id), f.source.reversed().map(\.id))
        XCTAssertNotEqual(updated.first?.id, captured.first?.id)
        XCTAssertFalse(updated.contains { $0.id == f.source.first?.id })
        let ui = try await store.history(nil, offset: 0)
        XCTAssertEqual(ui.items.count, 100); XCTAssertEqual(ui.nextOffset, 100)
    }
    func testBacklogBeyondFirstPageImportsAllAndSurvivesRestartWithoutRepeat() async throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.directory) }
        let expected = Set(f.source.map(\.id))
        let first = try await replay(f, ticks: 2)
        XCTAssertEqual(first.count, 251); XCTAssertEqual(Set(first.map(\.id)), expected)
        // Единственный significant event находится за пределами первых100.
        let sent = await f.sink.sent(); XCTAssertEqual(sent, [f.source[0].id])
        let reopened = try await replay(f, ticks: 2)
        XCTAssertEqual(reopened.count, 251); XCTAssertEqual(Set(reopened.map(\.id)), expected)
        let repeated = await f.sink.sent(); XCTAssertEqual(repeated, sent)
    }
    func testCutoffAndHourNotificationFreshnessRemainUnchanged() async throws {
        let f = try fixture(oldEvents: true); defer { try? FileManager.default.removeItem(at: f.directory) }
        let events = try await replay(f)
        XCTAssertEqual(events.count, 250)
        XCTAssertFalse(events.contains { $0.id == f.source[0].id }) // До opt-in cutoff.
        XCTAssertTrue(events.contains { $0.id == f.source[1].id }) // История старше1h есть в inbox.
        let sent = await f.sink.sent(); XCTAssertEqual(sent, [f.source[2].id])
    }
    func testRuntimeLanguageDispatchPreservesBacklogAndDeniesExternalRoles() async throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.directory) }
        let live = try runtime(f)
        let before = await live.monitors.historyForDelivery().map(\.id)
        let request = LocalRPCRequest(domain: "athena", operation: "language.set", payload: Data("{\"preference\":\"en\"}".utf8))
        for role in [LocalRole.mcp, .worker] {
            do { _ = try await live.service.handle(role: role, request: request); XCTFail("Role bypass") }
            catch { XCTAssertEqual(error as? LocalRuntimeFailure, .denied) }
        }
        let result = try await live.service.handle(role: .gui, request: request)
        XCTAssertEqual(try LocalWire.decode(LocalLanguageStatus.self, result).preference, .en)
        let after = await live.monitors.historyForDelivery().map(\.id); XCTAssertEqual(after, before)
        await live.service.tick(); await live.service.tick()
        let inbox = try await live.automation.inbox.events(now: f.source[0].capturedAt.addingTimeInterval(1))
        XCTAssertEqual(inbox.count, f.source.count)
        await live.work.shutdown()
    }
}

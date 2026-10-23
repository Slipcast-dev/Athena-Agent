import Foundation
import XCTest
import EcosystemLocalIPC
import EcosystemLocalization
import EcosystemRuntimeSupport
@testable import MacAssistantCore
@testable import MacAssistant

/// Проверяется реальный обработчик monitor RPC, durable stores и tick в одном
/// процессе. Роль задаётся тестом; это не испытание подписи XPC и не GUI click.
/// Sink намеренно не вызывает macOS: личные разрешения уведомлений не меняются.
@MainActor
final class AthenaLanguageWorkflowTests: XCTestCase {
    private struct Runtime {
        let monitors: MonitorStore
        let automation: LocalAutomationService
        let work: AthenaQueuedWork
        let service: AthenaRuntimeService
    }

    private func runtime(directory: URL, sink: LanguageWorkflowNotificationSink) throws -> Runtime {
        let monitors = try MonitorStore(directory: directory)
        let automation = try LocalAutomationService(directory: directory, domain: "athena", notifications: sink)
        let grants = try AthenaLocalGrants(directory: directory)
        let source = LanguageWorkflowSystem()
        let work = try AthenaQueuedWork(
            queue: DurableTaskQueue(directory: directory.appendingPathComponent("queue"), agentID: .athena),
            grants: grants, system: source,
            diagnostics: SystemDiagnosticsService(systemInformation: source),
            storage: StorageAnalysisService(), monitors: monitors, monitorSystem: source
        )
        return Runtime(monitors: monitors, automation: automation, work: work,
                       service: AthenaRuntimeService(work: work, grants: grants, automation: automation))
    }

    private func monitorCall<T: Decodable>(
        _ store: MonitorStore, _ operation: String, _ value: MonitorRequest,
        role: LocalRole = .mcp, as type: T.Type
    ) async throws -> T {
        let data = try await MonitorControl.handle(store: store, role: role,
            request: LocalRPCRequest(domain: "athena", operation: operation, payload: LocalWire.encode(value)))
        return try LocalWire.decode(type, data)
    }

    private struct Phase {
        let rule: MonitorRule
        let fingerprint: String
        let historyIDs: [UUID]
        let inbox: [LocalInboxEvent]
        let delivered: [UUID]
    }

    /// Отдельный async scope освобождает и queue ownership lease; shutdown сам
    /// по себе завершает работу, но не уничтожает ещё удерживаемый Runtime.
    private func firstPhase(directory: URL, sink: LanguageWorkflowNotificationSink) async throws -> Phase {
        let live = try runtime(directory: directory, sink: sink)
        do {
        try await live.automation.configure(paused: nil, notificationsEnabled: true)
        let ru = AthenaLocalization(language: .russian)
        let en = AthenaLocalization(language: .english)
        var rule = MonitorRule()
        // Сохранённое внешнее имя с символами формата нельзя трактовать как ключ
        // перевода. Пороги/окно минимальны, но проходят настоящую validate().
        rule.name = "Личная проверка %@ / CPU"
        rule.metric = .storage
        rule.windowSamples = 2
        rule.intervalSeconds = 60
        rule.warning = 40; rule.critical = 45; rule.recovery = 30
        let proposed: MonitorEntry = try await monitorCall(live.monitors, "monitor.propose",
            MonitorRequest(rule: rule), as: MonitorEntry.self)
        // Сервер намеренно выдаёт собственный UUID; одобряем именно его rule.
        rule = proposed.rule
        XCTAssertFalse(proposed.enabled)
        let plan: MonitorPlan = try await monitorCall(live.monitors, "monitor.request_enable",
            MonitorRequest(monitorID: proposed.id), as: MonitorPlan.self)
        XCTAssertEqual(plan.fingerprint, rule.fingerprint)
        let approval = MonitorRequest(planID: plan.id, fingerprint: plan.fingerprint)
        do {
            let _: MonitorEntry = try await monitorCall(live.monitors, "monitor.approve", approval, as: MonitorEntry.self)
            XCTFail("MCP must not approve its own monitoring plan")
        } catch { XCTAssertEqual(error as? LocalRuntimeFailure, .denied) }
        let enabled: MonitorEntry = try await monitorCall(live.monitors, "monitor.approve", approval,
            role: .gui, as: MonitorEntry.self)
        XCTAssertTrue(enabled.enabled)
        XCTAssertEqual(enabled.rule, rule)

        // Рендер enum labels и плана использует тот же allowlist, что UI; смена
        // языка не сериализует rule заново и не выдаёт нового согласия.
        let bytesBefore = try Data(contentsOf: directory.appendingPathComponent("monitors-v1.json"))
        let frozen = ConfirmationLanguage(language: .russian)
        XCTAssertEqual(en.text(MonitorViewModel.metricTitle(rule.metric)), "Storage")
        XCTAssertEqual(ru.text(MonitorPresentation.statusTitle(.critical)), "Критическое состояние")
        XCTAssertEqual(en.text(MonitorPresentation.statusTitle(.critical)), "Critical")
        XCTAssertEqual(en.render(.verbatim(rule.name)), rule.name)
        XCTAssertEqual(AthenaLocalization(language: frozen.language).text("Подтвердить мониторинг"),
                       "Подтвердить мониторинг")
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent("monitors-v1.json")), bytesBefore)

        let now = Date()
        for sample in [now, now] {
            let metrics = SystemMetrics(capturedAt: sample, cpuUsagePercent: 20, totalMemoryBytes: 1000,
                usedMemoryBytes: 500, availableMemoryBytes: 500, memoryPressure: nil,
                totalStorageBytes: 1000, availableStorageBytes: 500)
            try await live.monitors.record(id: proposed.id, revision: plan.fingerprint,
                                           metrics: metrics, now: sample)
        }
        let history = try await live.monitors.history(proposed.id, offset: 0).items
        XCTAssertEqual(history.count, 1)
        let event = try XCTUnwrap(history.first)
        XCTAssertEqual(event.status, .critical)
        XCTAssertTrue(event.notificationEligible)
        await live.service.tick(); await live.service.tick()
        let inbox = try await live.automation.inbox.events()
        XCTAssertEqual(inbox.map(\.id), [event.id])
        let delivered = await sink.sent()
        XCTAssertEqual(delivered, [event.id])
        let stored = try await live.monitors.entry(proposed.id)
        XCTAssertEqual(stored.rule, rule)
        XCTAssertEqual(stored.approvedRevision, plan.fingerprint)
        let snapshot = try Data(contentsOf: directory.appendingPathComponent("monitors-v1.json"))
        for language in AgentLanguage.allCases {
            let text = AthenaLocalization(language: language).text(MonitorPresentation.statusTitle(event.status))
            XCTAssertFalse(text.isEmpty)
            XCTAssertNotEqual(text, AthenaLocalization.unavailable)
        }
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent("monitors-v1.json")), snapshot)
        await live.work.shutdown()

        return Phase(rule: rule, fingerprint: plan.fingerprint, historyIDs: history.map(\.id),
                     inbox: inbox, delivered: delivered)
        } catch {
            await live.work.shutdown()
            throw error
        }
    }

    func testLanguageRenderingPreservesApprovedMonitorAndDurableEventReplay() async throws {
        let directory = URL(fileURLWithPath: "/private/tmp/athena-language-workflow-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                               attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let sink = LanguageWorkflowNotificationSink()
        let saved = try await firstPhase(directory: directory, sink: sink)

        // Все stores/queue открываются заново: receipt и ID события должны
        // пережить restart, а повторные tick не создают вторую доставку.
        let reopened = try runtime(directory: directory, sink: sink)
        await reopened.service.tick(); await reopened.service.tick()
        let afterHistory = try await reopened.monitors.history(saved.rule.id, offset: 0).items
        XCTAssertEqual(afterHistory.map(\.id), saved.historyIDs)
        let afterInbox = try await reopened.automation.inbox.events()
        XCTAssertEqual(afterInbox.map(\.id), saved.inbox.map(\.id))
        XCTAssertEqual(afterInbox.map(\.summary), saved.inbox.map(\.summary))
        let sentAgain = await sink.sent()
        XCTAssertEqual(sentAgain, saved.delivered)
        let afterRule = try await reopened.monitors.entry(saved.rule.id)
        XCTAssertEqual(afterRule.rule, saved.rule)
        XCTAssertEqual(afterRule.approvedRevision, saved.fingerprint)
        await reopened.work.shutdown()
    }
}

private actor LanguageWorkflowNotificationSink: LocalNotificationSending {
    private var ids: [UUID] = []
    func authorization() -> String { "authorized" }
    func requestAuthorization() -> String { "authorized" }
    func send(id: UUID, title: String, body: String) { ids.append(id) }
    func sent() -> [UUID] { ids }
}

/// Даже при случайном дополнительном poll используются только синтетические
/// метрики, а не состояние пользовательской машины и не её файлы.
private struct LanguageWorkflowSystem: SystemInformationProviding {
    func systemInfo() async throws -> SystemInfo {
        SystemInfo(modelName: "Fixture", operatingSystemVersion: "Fixture", architecture: "arm64",
                   physicalCPUCoreCount: 4, logicalCPUCoreCount: 4)
    }
    func systemMetrics() async throws -> SystemMetrics {
        SystemMetrics(cpuUsagePercent: 20, totalMemoryBytes: 1000, usedMemoryBytes: 500,
                      availableMemoryBytes: 500, memoryPressure: nil,
                      totalStorageBytes: 1000, availableStorageBytes: 500)
    }
}

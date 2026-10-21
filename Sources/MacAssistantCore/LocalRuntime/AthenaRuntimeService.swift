import Darwin
import Foundation
import EcosystemLocalIPC

public actor AthenaRuntimeService {
    private let work: AthenaQueuedWork
    private let grants: AthenaLocalGrants
    public let automation: LocalAutomationService?
    private let login: LocalLoginRegistration?
    private let history: LocalMCPHistory?
    private let instanceID = UUID()
    private var changing = false
    private var admitting = 0
    public init(work: AthenaQueuedWork, grants: AthenaLocalGrants, automation: LocalAutomationService? = nil, login: LocalLoginRegistration? = nil, history: LocalMCPHistory? = nil) { self.work = work; self.grants = grants; self.automation = automation; self.login = login; self.history = history }
    private var backgroundWake: (@Sendable () -> Void)?
    public func setBackgroundWake(_ action: @escaping @Sendable () -> Void) { backgroundWake = action }
    public func nextBackgroundDelay() async -> TimeInterval? {
        var values: [TimeInterval] = []
        if !(await automation?.paused() ?? false),
           let status = try? await work.emergencyStatus(), !status.stopped,
           let delay = await work.monitors?.nextBackgroundDelay() { values.append(delay) }
        if let delay = await automation?.notificationRetryDelay() { values.append(delay) }
        // Ошибка импорта не должна оставить scheduler без срока, если монитор
        // уже выключен, а непринесённое событие ещё отсутствует во входящих.
        if monitorReplayPending { values.append(5) }
        return values.min()
    }
    private var monitorReplayPending = false
    private var ticking = false
    public func tick() async {
        guard !ticking else { return }; ticking = true; defer { ticking = false }
        if !(await automation?.paused() ?? false) { try? await work.pollMonitors() }
        guard let automation, let monitors = work.monitors else { return }
        do {
            monitorReplayPending = true
            let history = await monitors.historyForDelivery()
            for event in history {
                try await automation.record(id: event.id, kind: "monitor." + event.status.rawValue, capability: "monitor.history", capturedAt: event.capturedAt, significant: event.notificationEligible)
            }
            // Не сохраняем high-water mark до полной партии: успешные append
            // уже durable по ID, поэтому повтор после частичного сбоя безопасен.
            monitorReplayPending = false
        } catch { /* История сохранена; retry через5s даже без enabled monitors. */ }
        await automation.flushNotifications()
    }
    public func handle(role: LocalRole, clientID: LocalMCPClient? = nil, request: LocalRPCRequest) async throws -> Data {
        if request.operation.hasPrefix("operations.emergency_") {
            guard role == .gui else { throw LocalRuntimeFailure.denied }
            _ = try LocalWire.decode(LocalEmpty.self, request.payload, keys: [])
            switch request.operation {
            case "operations.emergency_status": return try LocalWire.encode(await work.emergencyStatus())
            case "operations.emergency_stop": return try LocalWire.encode(await work.emergencyStop())
            case "operations.emergency_resume":
                let result = try await work.resumeAdmission(); backgroundWake?(); return try LocalWire.encode(result)
            default: throw LocalRuntimeFailure.denied
            }
        }
        if request.operation.hasPrefix("mcp.") {
            guard role == .mcp, let history else { throw LocalRuntimeFailure.denied }
            return try await history.handle(operation: request.operation, payload: request.payload, client: clientID ?? .legacy)
        }
        if request.operation == "automation.login_status" || request.operation == "automation.login_configure" {
            guard role == .gui, let login else { throw LocalRuntimeFailure.denied }
            if request.operation == "automation.login_status" {
                _ = try LocalWire.decode(LocalEmpty.self, request.payload, keys: [])
                return try LocalWire.encode(login.status())
            }
            struct Change: Decodable { let enabled: Bool }
            let value = try LocalWire.decode(Change.self, request.payload, keys: ["enabled"])
            return try LocalWire.encode(login.setEnabled(value.enabled))
        }
        if request.operation.hasPrefix("automation.") || request.operation.hasPrefix("events.") {
            guard let automation else { throw LocalRuntimeFailure.denied }
            let result = try await LocalAutomationControl.handle(service: automation, policy: work.policy, role: role, client: clientID, request: request)
            if ["automation.configure", "automation.request_notifications"].contains(request.operation) { backgroundWake?() }
            return result
        }
        if request.operation.hasPrefix("access."), let policy = work.policy {
            let scope = LocalAccessScope(roots: [], capabilities: policy.capabilities)
            let result = try await LocalAccessControl.handle(policy: policy, scope: scope, role: role, client: clientID, request: request)
            if request.operation == "access.approve" {
                let grant = try LocalWire.decode(LocalAccessGrant.self, result); try await work.cancelClient(grant.draft.client)
            } else if request.operation == "access.revoke", let value = try JSONSerialization.jsonObject(with: result) as? [String: Any], let text = value["client"] as? String, let client = LocalMCPClient(rawValue: text) { try await work.cancelClient(client) }
            return result
        }
        if role == .mcp, let policy = work.policy, !["runtime.status", "work.submit", "task.get", "task.cancel", "work.tasks"].contains(request.operation) {
            guard !request.operation.hasPrefix("recovery.") else { throw LocalRuntimeFailure.denied }
            let ticket = try await policy.authorize(client: clientID ?? .legacy, capability: request.operation)
            let result = try await permittedHandle(role: role, clientID: clientID, accessTicket: ticket, request: request)
            return try await policy.export(result, ticket: ticket)
        }
        return try await permittedHandle(role: role, clientID: clientID, request: request)
    }
    private func permittedHandle(role: LocalRole, clientID: LocalMCPClient?, accessTicket: LocalAccessTicket? = nil, request: LocalRPCRequest) async throws -> Data {
        if request.operation.hasPrefix("monitor.") {
            guard role != .worker, let store = work.monitors else { throw LocalRuntimeFailure.denied }
            return try await MonitorControl.handle(store: store, role: role, policy: work.policy, accessTicket: accessTicket, request: request)
        }
        if request.operation == "diagnostics.history" {
            guard role != .worker else { throw LocalRuntimeFailure.denied }
            let query = try LocalWire.decode(MonitorRequest.self, request.payload, keys: ["offset"])
            let offset = query.offset ?? 0
            guard (0...1_000_000).contains(offset) else { throw LocalRuntimeFailure.invalidRequest }
            let rows = try await work.queue.tasks(limit: 100, offset: offset)
            var items: [[String: Any]] = []
            for row in rows where ["diagnostics.run", "system.get_metrics", "system.get_info", "storage.get_overview"].contains(row.capabilityID) {
                if let allowed = try? await work.task(row.id, role: role, clientID: clientID) { items.append(try AthenaPublicResult.task(allowed)) }
            }
            return try JSONSerialization.data(withJSONObject: ["items": items, "nextOffset": rows.count == 100 ? offset + 100 as Any : NSNull()])
        }
        if request.operation.hasPrefix("recovery.") { return try await work.recovery.handle(role: role, request: request) }
        // Отдельный GUI endpoint не расширяет доступ MCP или worker. Список
        // ограничен последними 100 записями; интерфейс явно сообщает эту границу.
        if request.operation == "operations.tasks" {
            guard role == .gui else { throw LocalRuntimeFailure.denied }
            _ = try LocalWire.decode(LocalEmpty.self, request.payload, keys: [])
            return try LocalWire.encode(try await work.queue.tasks(limit: 100).map {
                LocalOperationalTask(id: $0.id, status: $0.status)
            })
        }
        switch request.operation {
        case "runtime.status":
            _ = try LocalWire.decode(LocalEmpty.self, request.payload, keys: [])
            return try JSONSerialization.data(withJSONObject: ["domain": "athena", "processID": getpid(), "instanceID": instanceID.uuidString, "runtimeIntegrated": true, "healthy": await work.isHealthy()])
        case "work.submit":
            guard !changing else { throw LocalRuntimeFailure.busy }
            let value = try LocalWire.decode(AthenaSubmission.self, request.payload, keys: ["capability", "job", "key", "deadlineAt"])
            let object = try JSONSerialization.jsonObject(with: request.payload) as? [String: Any]
            guard let job = object?["job"] as? [String: Any], Set(job.keys).isSubset(of: ["rootID", "minimumSizeBytes"]), value.job.requesterRole == nil else { throw LocalRuntimeFailure.invalidRequest }
            admitting += 1; defer { admitting -= 1 }
            return try LocalWire.encode(LocalTaskID(try await work.submit(value, role: role, clientID: clientID).id))
        case "task.get", "task.cancel":
            let id = try LocalWire.decode(LocalTaskID.self, request.payload, keys: ["id"]).id
            if request.operation == "task.cancel" { try await work.cancel(id, role: role, clientID: clientID); return try LocalWire.encode(LocalEmpty()) }
            return try LocalWire.encode(try await work.task(id, role: role, clientID: clientID))
        case "work.tasks":
            _ = try LocalWire.decode(LocalEmpty.self, request.payload, keys: [])
            guard role != .worker else { throw LocalRuntimeFailure.denied }
            return try LocalWire.encode(try await work.tasks(role: role, clientID: clientID))
        case "grant.add", "grant.revoke":
            guard role == .gui, !changing, admitting == 0 else { throw LocalRuntimeFailure.denied }
            changing = true; defer { changing = false }
            if request.operation == "grant.add" {
                let transfer = try LocalWire.decode(AthenaRootTransfer.self, request.payload, keys: ["bookmark"])
                return try LocalWire.encode(LocalTaskID(try await grants.add(transfer)))
            }
            let id = try LocalWire.decode(LocalTaskID.self, request.payload, keys: ["id"]).id
            try await work.revoke(id)
            return try LocalWire.encode(LocalEmpty())
        default: throw LocalRuntimeFailure.denied
        }
    }
}

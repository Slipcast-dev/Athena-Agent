import CryptoKit
import Foundation
import EcosystemContracts
import EcosystemRuntimeSupport
import EcosystemLocalIPC

public actor AthenaQueuedWork {
    public let queue: DurableTaskQueue
    public let recovery: LocalRecoveryService
    public let monitors: MonitorStore?
    public let policy: LocalAccessPolicy?
    private let executor: DurableTaskExecutor
    private let grants: AthenaLocalGrants
    public init(queue: DurableTaskQueue, grants: AthenaLocalGrants,
                system: any SystemInformationProviding, diagnostics: any SystemDiagnosing,
                storage: any StorageAnalyzing, monitors: MonitorStore? = nil, monitorSystem: (any SystemInformationProviding)? = nil, policy: LocalAccessPolicy? = nil) throws {
        self.queue = queue; self.grants = grants; self.monitors = monitors; self.policy = policy
        var operations: [String: RegisteredQueueOperation] = [
            "system.get_info": RegisteredQueueOperation(mutating: false) { _, context in
                let value = try await system.systemInfo(); try await context.checkpoint(); return try LocalWire.encode(value)
            },
            "system.get_metrics": RegisteredQueueOperation(mutating: false) { _, context in
                let value = try await system.systemMetrics(); try await context.checkpoint(); return try LocalWire.encode(value)
            },
            "diagnostics.run": RegisteredQueueOperation(mutating: false) { _, context in
                let value = try await diagnostics.runDiagnostics(); try await context.checkpoint(); return try LocalWire.encode(value)
            },
            "storage.get_overview": RegisteredQueueOperation(mutating: false) { _, context in
                let value = try await storage.storageOverview(); try await context.checkpoint(); return try LocalWire.encode(value)
            },
            "storage.scan": RegisteredQueueOperation(mutating: false) { data, context in
                let job = try ContractCodec.decode(TaskRequest<AthenaJob>.self, from: data).parameters
                guard let id = job.rootID, let minimum = job.minimumSizeBytes else { throw LocalRuntimeFailure.invalidRequest }
                let url = try await grants.resolve(id)
                guard url.startAccessingSecurityScopedResource() else { throw LocalRuntimeFailure.denied }
                defer { url.stopAccessingSecurityScopedResource() }
                let value = try await storage.scanDirectory(at: url, minimumSizeBytes: minimum)
                try await context.checkpoint()
                guard await grants.contains(id) else { throw LocalRuntimeFailure.denied }
                return try LocalWire.encode(value)
            }
        ]
        // Отдельный sampler предотвращает сброс базы CPU интерактивными клиентами.
        let monitoringSystem = monitorSystem ?? system
        if let monitors {
            operations["monitor.poll"] = RegisteredQueueOperation(mutating: false) { _, context in
                let due = await monitors.due()
                guard !due.isEmpty else { return try LocalWire.encode(LocalEmpty()) }
                let metrics: SystemMetrics?
                do { metrics = try await monitoringSystem.systemMetrics() }
                catch is CancellationError { throw CancellationError() }
                catch { metrics = nil }
                for entry in due {
                    try await context.checkpoint()
                    try await monitors.record(id: entry.id, revision: entry.rule.fingerprint, metrics: metrics, now: Date())
                }
                return try LocalWire.encode(LocalEmpty())
            }
        }
        // Тяжёлыми считаются операции с обходом ФС/хешированием/правилами,
        // а не быстрые metrics/info. Метка сохраняется при обёртке авторизации.
        let heavyCapabilities: Set<String> = ["storage.scan"]
        operations = Dictionary(uniqueKeysWithValues: operations.map { capability, operation in
            (capability, RegisteredQueueOperation(mutating: operation.mutating,
                workload: heavyCapabilities.contains(capability) ? .heavy : .light, perform: operation.perform))
        })
        if let policy {
            operations = operations.mapValues { operation in
                RegisteredQueueOperation(mutating: operation.mutating, workload: operation.workload) { data, context in
                    let job = try ContractCodec.decode(TaskRequest<AthenaJob>.self, from: data).parameters
                    guard job.requesterRole == .mcp else { return try await operation.perform(data, context) }
                    guard let ticket = job.accessTicket, ticket.client == job.requesterClientID else { throw LocalRuntimeFailure.denied }
                    let checked = context.withAuthorization { check in
                        switch check {
                        case .checkpoint: _ = try await policy.check(ticket)
                        case .root(let root): _ = try await policy.check(ticket, root: root)
                        case .budget(let objects, let bytes): _ = try await policy.check(ticket, objects: objects, bytes: bytes)
                        }
                    }
                    try await checked.checkpoint()
                    let result = try await operation.perform(data, checked)
                    try await checked.checkpoint(); return result
                }
            }
        }
        executor = try DurableTaskExecutor(queue: queue, operations: operations)
        recovery = LocalRecoveryService(queue: queue, executor: executor)
    }
    public func pollMonitors() async throws {
        guard let monitors, !(await monitors.due()).isEmpty else { return }
        _ = try await submit(AthenaSubmission(capability: "monitor.poll", job: AthenaJob(), key: UUID().uuidString), role: .worker)
    }
    public func emergencyStatus() async throws -> QueueEmergencyStatus { try await executor.emergencyStatus() }
    public func emergencyStop() async throws -> QueueEmergencyStatus { try await executor.emergencyStop() }
    public func resumeAdmission() async throws -> QueueEmergencyStatus { try await executor.resumeAdmission() }
    public func shutdown() async { _ = try? await executor.drain() }
    public func isHealthy() async -> Bool { await executor.isHealthy() }
    public func resume() async throws { await executor.startSupervision(); try await executor.resumeQueuedTasks() }
    func submit(_ value: AthenaSubmission, role: LocalRole, clientID: LocalMCPClient? = nil) async throws -> DurableTask {
        let capabilities = LocalAgentBridge.commands.map(\.id)
        guard (capabilities.contains(value.capability) && role != .worker) || (role == .gui && value.capability == "storage.scan") || (role == .worker && value.capability == "monitor.poll" && monitors != nil) else { throw LocalRuntimeFailure.denied }
        var job = value.job; job.requesterRole = role
        if role == .mcp {
            job.requesterClientID = clientID ?? .legacy
            if let policy { job.accessTicket = try await policy.authorize(client: clientID ?? .legacy, capability: value.capability) }
        }
        if value.capability == "storage.scan" {
            guard let id = job.rootID, await grants.contains(id), let minimum = job.minimumSizeBytes, minimum <= UInt64(Int64.max) else { throw LocalRuntimeFailure.denied }
        } else if job.rootID != nil || job.minimumSizeBytes != nil { throw LocalRuntimeFailure.invalidRequest }
        let formatter = ISO8601DateFormatter()
        var deadline = value.deadlineAt
        if let ticket = job.accessTicket, let policy {
            let expiry = try await policy.check(ticket).expiresAt
            if deadline == nil { deadline = formatter.string(from: expiry) }
            else {
                let stamp = try UTCTimestamp(deadline!)
                let expiryStamp = try UTCTimestamp(formatter.string(from: expiry))
                if stamp > expiryStamp { deadline = formatter.string(from: expiry) }
            }
        }
        let request = try TaskRequest(requestID: UUID(), agentID: .athena, capabilityID: value.capability,
            parameters: job, origin: .user, idempotencyKey: value.key, grantID: job.rootID,
            createdAt: UTCTimestamp(formatter.string(from: Date())), deadlineAt: try deadline.map { try UTCTimestamp($0) })
        // Независимые операции чтения могут стоять в очереди одновременно.
        // Ресурс стабилен при повторе ключа; один grant сканируется последовательно.
        let digest = SHA256.hash(data: Data(value.key.utf8)).map { String(format: "%02x", $0) }.joined()
        var resources = [value.capability == "monitor.poll" ? "athena.monitor" : "athena.job." + digest]
        if let id = job.rootID { resources.append("athena.root." + id.uuidString.lowercased()) }
        return try await executor.submit(QueueSubmission(request: request, resources: resources, mutating: false))
    }
    public func task(_ id: UUID, role: LocalRole, clientID: LocalMCPClient? = nil, includeResult: Bool = true) async throws -> DurableTask {
        guard var value = try await queue.task(id, includeResult: includeResult) else { throw LocalRuntimeFailure.invalidRequest }
        let job = try ContractCodec.decode(TaskRequest<AthenaJob>.self, from: value.request).parameters
        guard role == .gui || job.requesterRole == role else { throw LocalRuntimeFailure.denied }
        if role == .mcp {
            guard (job.requesterClientID ?? .legacy) == (clientID ?? .legacy) else { throw LocalRuntimeFailure.denied }
            if let policy {
                guard let ticket = job.accessTicket else { throw LocalRuntimeFailure.denied }; _ = try await policy.check(ticket)
                if let result = value.result { value.result = try await policy.export(result, ticket: ticket) }
                value = value.forExternalClient()
            }
        }
        if let root = job.rootID, !((await grants.contains(root))) { throw LocalRuntimeFailure.denied }
        if role == .mcp, let policy, let ticket = job.accessTicket { _ = try await policy.check(ticket, root: job.rootID) }
        return value
    }
    func cancel(_ id: UUID, role: LocalRole, clientID: LocalMCPClient? = nil) async throws { _ = try await task(id, role: role, clientID: clientID); try await executor.cancel(id) }
    public func cancelClient(_ client: LocalMCPClient) async throws {
        for task in try await queue.executingTasks() {
            let job = try ContractCodec.decode(TaskRequest<AthenaJob>.self, from: task.request).parameters
            if job.requesterRole == .mcp && (job.requesterClientID ?? .legacy) == client { try await executor.cancel(task.id) }
        }
    }
    func revoke(_ id: UUID) async throws {
        try await grants.revoke(id)
        if let task = try await queue.taskReserving("athena.root." + id.uuidString.lowercased()), !task.status.isTerminal {
            try await executor.cancel(task.id)
        }
    }
    func tasks(role: LocalRole, clientID: LocalMCPClient? = nil) async throws -> [AgentTask] {
        var result: [AgentTask] = []
        for value in try await queue.tasks(limit: 100) where !value.status.isTerminal {
            if role == .mcp, (try? await task(value.id, role: role, clientID: clientID)) == nil { continue }
            let job = try ContractCodec.decode(TaskRequest<AthenaJob>.self, from: value.request).parameters
            guard role == .gui || job.requesterRole == role, let status = AgentTaskStatus(rawValue: value.status.rawValue) else { continue }
            result.append(AgentTask(id: value.id, command: value.capabilityID, startedAt: value.createdAt, status: status))
        }
        return result.sorted { $0.startedAt < $1.startedAt }
    }
}

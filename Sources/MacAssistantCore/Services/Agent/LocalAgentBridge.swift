import Foundation
import EcosystemLocalIPC

/// Безопасный исполнитель разрешённых MCP-команд.
///
/// Важное ограничение: здесь нет запуска shell, AppleScript, передачи путей или
/// произвольных сетевых запросов. Добавление каждой новой команды требует явного
/// описания разрешения и отдельной проверки, а не передачи текста агента в систему.
public actor LocalAgentBridge: AgentBridging {
    public static let commands: [AgentCommand] = [
        AgentCommand(
            id: "system.get_info",
            title: "Сведения о Mac",
            permissionLevel: .readOnly,
            description: "Модель, версия macOS, архитектура и число ядер без серийного номера."
        ),
        AgentCommand(
            id: "system.get_metrics",
            title: "Показатели системы",
            permissionLevel: .readOnly,
            description: "Текущие CPU, память и свободное место без истории процессов."
        ),
        AgentCommand(
            id: "diagnostics.run",
            title: "Локальная диагностика",
            permissionLevel: .readOnly,
            description: "Структурированный отчёт и безопасные рекомендации, созданные локально."
        ),
        AgentCommand(
            id: "storage.get_overview",
            title: "Сводка накопителя",
            permissionLevel: .readOnly,
            description: "Общий и доступный объём системного накопителя без путей и списка файлов."
        )
    ]

    private let systemInformation: any SystemInformationProviding
    private let diagnostics: any SystemDiagnosing
    private let storage: any StorageAnalyzing
    private var tasks: [UUID: AgentTask] = [:]
    private var handles: [UUID: Task<AgentCommandResult, Error>] = [:]
    private let remote: Result<LocalRPCClient, Error>?

    public init(
        systemInformation: any SystemInformationProviding,
        diagnostics: any SystemDiagnosing,
        storage: any StorageAnalyzing,
        remote: Result<LocalRPCClient, Error>? = nil
    ) {
        self.systemInformation = systemInformation
        self.diagnostics = diagnostics
        self.storage = storage
        self.remote = remote
    }

    public func availableCommands() async -> [AgentCommand] {
        Self.commands
    }

    public func execute(command request: AgentCommandRequest) async throws -> AgentCommandResult {
        guard let command = Self.commands.first(where: { $0.id == request.commandID }) else {
            throw ServiceError.invalidInput(reason: "Команда внешнего агента не входит в разрешённый список.")
        }
        guard command.permissionLevel == .readOnly else {
            throw ServiceError.unavailable(feature: "Команда требует локального согласия")
        }

        if let remote {
            let client = try remote.get()
            let task: LocalTaskID = try await client.call("work.submit", AthenaSubmission(capability: command.id, job: AthenaJob(), key: UUID().uuidString))
            let data = try await client.waitForData(task.id, cancelOnCancellation: false)
            return try Self.remoteResult(for: command.id, data: data)
        }
        let task = AgentTask(command: command.id, status: .running)
        tasks[task.id] = task
        let operation = Task { try await self.result(for: command.id) }
        handles[task.id] = operation
        defer { tasks[task.id] = nil; handles[task.id] = nil }
        return try await withTaskCancellationHandler(operation: { try await operation.value }, onCancel: { operation.cancel() })
    }
    public func activeTasks() async -> [AgentTask] {
        if let remote { return (try? await remote.get().call("work.tasks", LocalEmpty(), as: [AgentTask].self)) ?? [] }
        return tasks.values.sorted { $0.startedAt < $1.startedAt }
    }
    public func cancelTask(id: UUID) async {
        if let remote { let _: LocalEmpty? = try? await remote.get().call("task.cancel", LocalTaskID(id)); return }
        guard var task = tasks[id], let handle = handles[id] else { return }
        task.status = .cancelling; tasks[id] = task
        // Запись остаётся активной до фактического возврата сервиса, а не до клика.
        handle.cancel()
    }

    private func result(for commandID: String) async throws -> AgentCommandResult {
        switch commandID {
        case "system.get_info":
            let info = try await systemInformation.systemInfo()
            return AgentCommandResult(
                commandID: commandID,
                text: "Mac: \(info.modelName); macOS: \(info.operatingSystemVersion); архитектура: \(info.architecture); ядер: \(info.physicalCPUCoreCount)/\(info.logicalCPUCoreCount)."
            )
        case "system.get_metrics":
            let metrics = try await systemInformation.systemMetrics()
            let cpu = metrics.cpuUsagePercent.map { String(format: "%.1f%%", $0) } ?? "подготавливается"
            return AgentCommandResult(
                commandID: commandID,
                text: "CPU: \(cpu); память: \(metrics.usedMemoryBytes)/\(metrics.totalMemoryBytes) байт; доступно на накопителе: \(metrics.availableStorageBytes) байт."
            )
        case "diagnostics.run":
            let report = try await diagnostics.runDiagnostics()
            let findings = report.findings.map(\.title).joined(separator: "; ")
            return AgentCommandResult(
                commandID: commandID,
                text: "Диагностика: \(report.status.rawValue). Находки: \(findings.isEmpty ? "нет" : findings)."
            )
        case "storage.get_overview":
            let overview = try await storage.storageOverview()
            return AgentCommandResult(
                commandID: commandID,
                text: "Накопитель: всего \(overview.totalBytes) байт, доступно \(overview.availableBytes) байт."
            )
        default:
            throw ServiceError.invalidInput(reason: "Неизвестная команда.")
        }
    }
    private static func remoteResult(for commandID: String, data: Data) throws -> AgentCommandResult {
        switch commandID {
        case "system.get_info":
            let info = try LocalWire.decode(SystemInfo.self, data)
            return AgentCommandResult(
                commandID: commandID,
                text: "Mac: \(info.modelName); macOS: \(info.operatingSystemVersion); архитектура: \(info.architecture); ядер: \(info.physicalCPUCoreCount)/\(info.logicalCPUCoreCount)."
            )
        case "system.get_metrics":
            let metrics = try LocalWire.decode(SystemMetrics.self, data)
            let cpu = metrics.cpuUsagePercent.map { String(format: "%.1f%%", $0) } ?? "подготавливается"
            return AgentCommandResult(
                commandID: commandID,
                text: "CPU: \(cpu); память: \(metrics.usedMemoryBytes)/\(metrics.totalMemoryBytes) байт; доступно на накопителе: \(metrics.availableStorageBytes) байт."
            )
        case "diagnostics.run":
            let report = try LocalWire.decode(DiagnosticReport.self, data)
            let findings = report.findings.map(\.title).joined(separator: "; ")
            return AgentCommandResult(
                commandID: commandID,
                text: "Диагностика: \(report.status.rawValue). Находки: \(findings.isEmpty ? "нет" : findings)."
            )
        case "storage.get_overview":
            let overview = try LocalWire.decode(StorageOverview.self, data)
            return AgentCommandResult(
                commandID: commandID,
                text: "Накопитель: всего \(overview.totalBytes) байт, доступно \(overview.availableBytes) байт."
            )
        default:
            throw ServiceError.invalidInput(reason: "Неизвестная команда.")
        }
    }
}

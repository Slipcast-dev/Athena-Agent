import Foundation
import EcosystemLocalization
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
            description: RuntimeLocalization.bilingual("Модель, версия macOS, архитектура и число ядер без серийного номера.")
        ),
        AgentCommand(
            id: "system.get_metrics",
            title: "Показатели системы",
            permissionLevel: .readOnly,
            description: RuntimeLocalization.bilingual("Текущие CPU, память и свободное место без истории процессов.")
        ),
        AgentCommand(
            id: "diagnostics.run",
            title: "Локальная диагностика",
            permissionLevel: .readOnly,
            description: RuntimeLocalization.bilingual("Структурированный отчёт и безопасные рекомендации, созданные локально.")
        ),
        AgentCommand(
            id: "storage.get_overview",
            title: "Сводка накопителя",
            permissionLevel: .readOnly,
            description: RuntimeLocalization.bilingual("Общий и доступный объём системного накопителя без путей и списка файлов.")
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
            throw ServiceError.invalidOperation(.commandNotAllowed)
        }
        guard command.permissionLevel == .readOnly else {
            throw ServiceError.unavailableFeature(.localConsent)
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
        // Локализуем только новый ответ; сохранённые результаты и UUID не меняются.
        let l10n = AgentLocalization(language: RuntimeLocalization.clientLanguage)
        switch commandID {
        case "system.get_info":
            let info = try await systemInformation.systemInfo()
            return AgentCommandResult(
                commandID: commandID,
                text: l10n.runtimeText("Mac: %@; macOS: %@; архитектура: %@; ядер: %@/%@.", info.modelName, info.operatingSystemVersion, info.architecture, String(info.physicalCPUCoreCount), String(info.logicalCPUCoreCount))
            )
        case "system.get_metrics":
            let metrics = try await systemInformation.systemMetrics()
            let cpu = metrics.cpuUsagePercent.map { String(format: "%.1f%%", $0) } ?? l10n.runtimeText("подготавливается")
            return AgentCommandResult(
                commandID: commandID,
                text: l10n.runtimeText("CPU: %@; память: %@/%@ байт; доступно на накопителе: %@ байт.", cpu, String(metrics.usedMemoryBytes), String(metrics.totalMemoryBytes), String(metrics.availableStorageBytes))
            )
        case "diagnostics.run":
            let report = try await diagnostics.runDiagnostics()
            // Код новых findings выбирает перевод; legacy/unknown остаются исходными.
            let findings = report.findings.map { $0.localized(using: l10n).title }.joined(separator: "; ")
            return AgentCommandResult(
                commandID: commandID,
                text: l10n.runtimeText("Диагностика: %@. Находки: %@.", report.status.rawValue, findings.isEmpty ? l10n.runtimeText("нет") : findings)
            )
        case "storage.get_overview":
            let overview = try await storage.storageOverview()
            return AgentCommandResult(
                commandID: commandID,
                text: l10n.runtimeText("Накопитель: всего %@ байт, доступно %@ байт.", String(overview.totalBytes), String(overview.availableBytes))
            )
        default:
            throw ServiceError.invalidOperation(.unknownCommand)
        }
    }
    private static func remoteResult(for commandID: String, data: Data) throws -> AgentCommandResult {
        // Локализуем только новый ответ; сохранённые результаты и UUID не меняются.
        let l10n = AgentLocalization(language: RuntimeLocalization.clientLanguage)
        switch commandID {
        case "system.get_info":
            let info = try LocalWire.decode(SystemInfo.self, data)
            return AgentCommandResult(
                commandID: commandID,
                text: l10n.runtimeText("Mac: %@; macOS: %@; архитектура: %@; ядер: %@/%@.", info.modelName, info.operatingSystemVersion, info.architecture, String(info.physicalCPUCoreCount), String(info.logicalCPUCoreCount))
            )
        case "system.get_metrics":
            let metrics = try LocalWire.decode(SystemMetrics.self, data)
            let cpu = metrics.cpuUsagePercent.map { String(format: "%.1f%%", $0) } ?? l10n.runtimeText("подготавливается")
            return AgentCommandResult(
                commandID: commandID,
                text: l10n.runtimeText("CPU: %@; память: %@/%@ байт; доступно на накопителе: %@ байт.", cpu, String(metrics.usedMemoryBytes), String(metrics.totalMemoryBytes), String(metrics.availableStorageBytes))
            )
        case "diagnostics.run":
            let report = try LocalWire.decode(DiagnosticReport.self, data)
            // Код новых findings выбирает перевод; legacy/unknown остаются исходными.
            let findings = report.findings.map { $0.localized(using: l10n).title }.joined(separator: "; ")
            return AgentCommandResult(
                commandID: commandID,
                text: l10n.runtimeText("Диагностика: %@. Находки: %@.", report.status.rawValue, findings.isEmpty ? l10n.runtimeText("нет") : findings)
            )
        case "storage.get_overview":
            let overview = try LocalWire.decode(StorageOverview.self, data)
            return AgentCommandResult(
                commandID: commandID,
                text: l10n.runtimeText("Накопитель: всего %@ байт, доступно %@ байт.", String(overview.totalBytes), String(overview.availableBytes))
            )
        default:
            throw ServiceError.invalidOperation(.unknownCommand)
        }
    }
}

import XCTest
@testable import MacAssistantCore

final class LocalAgentBridgeTests: XCTestCase {
    func testBridgePublishesOnlyReadOnlyAllowlist() async {
        let bridge = makeBridge()
        let commands = await bridge.availableCommands()

        XCTAssertEqual(commands.map(\.id), [
            "system.get_info",
            "system.get_metrics",
            "diagnostics.run",
            "storage.get_overview"
        ])
        XCTAssertTrue(commands.allSatisfy { $0.permissionLevel == .readOnly })
    }

    func testBridgeReturnsSanitizedSystemInformation() async throws {
        let bridge = makeBridge()

        let result = try await bridge.execute(command: AgentCommandRequest(commandID: "system.get_info"))

        XCTAssertEqual(result.commandID, "system.get_info")
        XCTAssertTrue(result.text.contains("MacBook Pro"))
        // Серийный номер никогда не входит в модель SystemInfo и не может оказаться в ответе моста.
        XCTAssertFalse(result.text.contains("SERIAL-SECRET"))
    }

    func testBridgeRejectsCommandsOutsideAllowlist() async {
        let bridge = makeBridge()

        do {
            _ = try await bridge.execute(command: AgentCommandRequest(commandID: "shell.execute"))
            XCTFail("Команда shell не должна быть доступна внешнему агенту")
        } catch let error as ServiceError {
            guard case .invalidInput = error else {
                return XCTFail("Ожидалась ошибка allowlist, получено: \(error)")
            }
        } catch {
            XCTFail("Получена неожиданная ошибка: \(error)")
        }
    }

    func testCancellationStopsActualServiceTask() async throws {
        let service = CancellableAgentSystem()
        let bridge = LocalAgentBridge(systemInformation: service, diagnostics: AgentDiagnosticsService(), storage: AgentStorageService())
        let operation = Task { try await bridge.execute(command: AgentCommandRequest(commandID: "system.get_info")) }
        for _ in 0..<100 {
            if await service.started { break }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        let active = await bridge.activeTasks()
        XCTAssertEqual(active.count, 1)
        guard let id = active.first?.id else { operation.cancel(); return XCTFail("No active task") }
        await bridge.cancelTask(id: id)
        do { _ = try await operation.value; XCTFail("Cancelled operation succeeded") }
        catch is CancellationError { }
        let cancelled = await service.cancelled
        XCTAssertTrue(cancelled)
        let remaining = await bridge.activeTasks(); XCTAssertTrue(remaining.isEmpty)
    }

    private func makeBridge() -> LocalAgentBridge {
        LocalAgentBridge(
            systemInformation: AgentSystemService(),
            diagnostics: AgentDiagnosticsService(),
            storage: AgentStorageService()
        )
    }
}

private struct AgentSystemService: SystemInformationProviding {
    func systemInfo() async throws -> SystemInfo {
        SystemInfo(
            modelName: "MacBook Pro",
            operatingSystemVersion: "macOS 14.0",
            architecture: "arm64",
            physicalCPUCoreCount: 8,
            logicalCPUCoreCount: 8
        )
    }

    func systemMetrics() async throws -> SystemMetrics {
        SystemMetrics(
            cpuUsagePercent: 12.5,
            totalMemoryBytes: 100,
            usedMemoryBytes: 50,
            availableMemoryBytes: 50,
            memoryPressure: .normal,
            totalStorageBytes: 100,
            availableStorageBytes: 40
        )
    }
}

private struct AgentDiagnosticsService: SystemDiagnosing {
    func runDiagnostics() async throws -> DiagnosticReport {
        DiagnosticReport(
            applicationVersion: "0.1.0",
            operatingSystemVersion: "macOS 14.0",
            metrics: try await AgentSystemService().systemMetrics(),
            findings: [],
            status: .completed
        )
    }
}

private struct AgentStorageService: StorageAnalyzing {
    func storageOverview() async throws -> StorageOverview {
        StorageOverview(totalBytes: 100, availableBytes: 40)
    }

    func scanDirectory(at _: URL, minimumSizeBytes _: UInt64) async throws -> [StorageItem] {
        []
    }
}

/// Короткий настоящий отменяемый async boundary, без ожидания произвольного таймера теста.
private actor CancellableAgentSystem: SystemInformationProviding {
    private(set) var started = false
    private(set) var cancelled = false
    func systemInfo() async throws -> SystemInfo {
        started = true
        do { try await Task.sleep(nanoseconds: 500_000_000) }
        catch { cancelled = true; throw error }
        return try await AgentSystemService().systemInfo()
    }
    func systemMetrics() async throws -> SystemMetrics { try await AgentSystemService().systemMetrics() }
}

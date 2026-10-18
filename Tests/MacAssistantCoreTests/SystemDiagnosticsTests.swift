import XCTest
@testable import MacAssistantCore

final class SystemDiagnosticsTests: XCTestCase {
    func testSystemInformationServiceProvidesSystemIdentity() async throws {
        let service = SystemInformationService()
        let info = try await service.systemInfo()

        XCTAssertFalse(info.modelName.isEmpty)
        XCTAssertFalse(info.operatingSystemVersion.isEmpty)
        XCTAssertGreaterThan(info.physicalCPUCoreCount, 0)
        XCTAssertGreaterThanOrEqual(info.logicalCPUCoreCount, info.physicalCPUCoreCount)
    }

    func testCPUUsageUsesDifferenceBetweenSnapshots() {
        let previous = CPUTimeSnapshot(user: 100, system: 50, idle: 850, nice: 0)
        let current = CPUTimeSnapshot(user: 160, system: 90, idle: 950, nice: 0)
        XCTAssertEqual(CPUUsageCalculator.usagePercent(previous: previous, current: current), 50)
    }

    func testCPUUsageReturnsNilWithoutElapsedTicks() {
        let snapshot = CPUTimeSnapshot(user: 10, system: 5, idle: 85, nice: 0)
        XCTAssertNil(CPUUsageCalculator.usagePercent(previous: snapshot, current: snapshot))
    }

    func testMemoryUsageTreatsInactivePagesAsAvailable() {
        let snapshot = MemoryPageSnapshot(pageSize: 4_096, freePages: 10, inactivePages: 20)
        let available = MemoryUsageCalculator.availableBytes(from: snapshot)
        XCTAssertEqual(available, 122_880)
        XCTAssertEqual(MemoryUsageCalculator.usedBytes(totalBytes: 409_600, availableBytes: available), 286_720)
    }

    func testDiagnosticReportWarnsWhenStorageExceedsWarningThreshold() {
        let findings = DiagnosticFindingFactory.makeFindings(
            for: makeMetrics(cpuUsagePercent: 10, totalStorageBytes: 1_000, availableStorageBytes: 150),
            thresholds: .init()
        )
        XCTAssertEqual(findings.map(\.severity), [.warning])
        XCTAssertEqual(findings.first?.title, "Мало места на накопителе")
    }

    func testDiagnosticReportDoesNotTreatMemoryUsageAloneAsWarning() {
        let findings = DiagnosticFindingFactory.makeFindings(
            for: makeMetrics(cpuUsagePercent: 10, totalMemoryBytes: 1_000, usedMemoryBytes: 990, totalStorageBytes: 1_000, availableStorageBytes: 500),
            thresholds: .init()
        )
        XCTAssertEqual(findings.map(\.severity), [.info])
    }

    func testDiagnosticsServiceBuildsCompletedStructuredReport() async throws {
        let source = StaticSystemInformationService(
            info: SystemInfo(modelName: "TestMac", operatingSystemVersion: "macOS Test", architecture: "arm64", physicalCPUCoreCount: 4, logicalCPUCoreCount: 8),
            metrics: makeMetrics(cpuUsagePercent: 20, totalStorageBytes: 1_000, availableStorageBytes: 500)
        )
        let service = SystemDiagnosticsService(systemInformation: source, applicationVersion: "0.1.0-test")

        let report = try await service.runDiagnostics()

        XCTAssertEqual(report.applicationVersion, "0.1.0-test")
        XCTAssertEqual(report.operatingSystemVersion, "macOS Test")
        XCTAssertEqual(report.status, .completed)
        XCTAssertEqual(report.findings.map(\.severity), [.info])
    }

    private func makeMetrics(cpuUsagePercent: Double?, totalMemoryBytes: UInt64 = 1_000, usedMemoryBytes: UInt64 = 100, totalStorageBytes: UInt64, availableStorageBytes: UInt64) -> SystemMetrics {
        SystemMetrics(cpuUsagePercent: cpuUsagePercent, totalMemoryBytes: totalMemoryBytes, usedMemoryBytes: usedMemoryBytes, availableMemoryBytes: totalMemoryBytes - usedMemoryBytes, memoryPressure: nil, totalStorageBytes: totalStorageBytes, availableStorageBytes: availableStorageBytes)
    }
}

/// Детерминированный источник подтверждает структуру отчёта без ожидания
/// реального CPU-снимка и без зависимости от состояния тестового Mac.
private struct StaticSystemInformationService: SystemInformationProviding {
    let info: SystemInfo
    let metrics: SystemMetrics

    func systemInfo() async throws -> SystemInfo { info }
    func systemMetrics() async throws -> SystemMetrics { metrics }
}

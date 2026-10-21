import XCTest
@testable import MacAssistant
import MacAssistantCore

private actor DashboardCounter: SystemInformationProviding {
    private var infoCalls = 0
    private var metricCalls = 0
    func counts() -> (Int, Int) { (infoCalls, metricCalls) }
    func systemInfo() async throws -> SystemInfo {
        infoCalls += 1
        return SystemInfo(modelName: "Test", operatingSystemVersion: "Test", architecture: "arm64", physicalCPUCoreCount: 4, logicalCPUCoreCount: 4)
    }
    func systemMetrics() async throws -> SystemMetrics {
        metricCalls += 1
        return SystemMetrics(cpuUsagePercent: 20, totalMemoryBytes: 1000, usedMemoryBytes: 100,
            availableMemoryBytes: 900, memoryPressure: nil, totalStorageBytes: 1000, availableStorageBytes: 500)
    }
}

@MainActor
final class DashboardEnergyTests: XCTestCase {
    func testRefreshCachesStaticInformationButUpdatesMetrics() async {
        let source = DashboardCounter()
        let actual = DashboardViewModel(systemInformation: source)
        await actual.refresh(); await actual.refresh()
        let counts = await source.counts()
        XCTAssertEqual(counts.0, 1); XCTAssertEqual(counts.1, 2)
    }
    func testCancelledVisibilityLoopDoesNotRequestMetrics() async {
        let source = DashboardCounter()
        let model = DashboardViewModel(systemInformation: source)
        let task = Task { await model.refreshWhileVisible() }
        task.cancel(); await task.value
        let counts = await source.counts()
        XCTAssertEqual(counts.0, 0); XCTAssertEqual(counts.1, 0)
    }
}

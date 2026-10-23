import XCTest
@testable import MacAssistant
import MacAssistantCore

private actor IdentityCounter: SystemInformationProviding {
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

private actor RetryingIdentitySource: SystemInformationProviding {
    private var calls = 0
    func systemInfo() throws -> SystemInfo {
        calls += 1
        if calls == 1 { throw CocoaError(.fileReadUnknown) }
        return .init(modelName: "Fixture", operatingSystemVersion: "Fixture", architecture: "arm64", physicalCPUCoreCount: 4, logicalCPUCoreCount: 8)
    }
    func systemMetrics() throws -> SystemMetrics { throw CocoaError(.featureUnsupported) }
}

@MainActor
final class SystemIdentityTests: XCTestCase {
    func testSettingsCacheStaticInformationWithoutPollingMetrics() async {
        let source = IdentityCounter()
        let actual = SystemIdentityViewModel(systemInformation: source)
        await actual.load(); await actual.load()
        let counts = await source.counts()
        XCTAssertEqual(counts.0, 1); XCTAssertEqual(counts.1, 0)
    }
    func testCancelledLoadDoesNotRequestSystemData() async {
        let source = IdentityCounter()
        let model = SystemIdentityViewModel(systemInformation: source)
        let task = Task { withUnsafeCurrentTask { $0?.cancel() }; await model.load() }
        task.cancel(); await task.value
        let counts = await source.counts()
        XCTAssertEqual(counts.0, 0); XCTAssertEqual(counts.1, 0)
    }
    func testExplicitRefreshReloadsInformationWithoutRequestingMetrics() async {
        let source = IdentityCounter()
        let actual = SystemIdentityViewModel(systemInformation: source)
        await actual.load(); await actual.load(force: true)
        let counts = await source.counts()
        XCTAssertEqual(counts.0, 2); XCTAssertEqual(counts.1, 0)
    }
    func testUnavailablePreviewDoesNotStartLiveSystemRead() async {
        let model = SystemIdentityViewModel()
        await model.load(); XCTAssertNil(model.info); XCTAssertNil(model.error); XCTAssertFalse(model.loading)
    }

    func testFailedReadCanRetryAndClearError() async {
        let model = SystemIdentityViewModel(systemInformation: RetryingIdentitySource())
        await model.load(); XCTAssertNotNil(model.error); XCTAssertNil(model.info); XCTAssertFalse(model.loading)
        await model.load(); XCTAssertNil(model.error); XCTAssertNotNil(model.info); XCTAssertFalse(model.loading)
    }

}

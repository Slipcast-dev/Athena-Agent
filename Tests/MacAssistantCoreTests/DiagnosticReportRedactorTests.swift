import XCTest
@testable import MacAssistantCore

final class DiagnosticReportRedactorTests: XCTestCase {
    func testRedactorDoesNotIncludeModelOrIdentifiers() {
        let metrics = SystemMetrics(cpuUsagePercent: 10, totalMemoryBytes: 1, usedMemoryBytes: 1, availableMemoryBytes: nil, memoryPressure: nil, totalStorageBytes: 100, availableStorageBytes: 50)
        let report = DiagnosticReport(applicationVersion: "secret-version", operatingSystemVersion: "macOS", metrics: metrics, findings: [], status: .completed)
        let text = DiagnosticReportRedactor.text(for: report)
        XCTAssertTrue(text.hasPrefix("Диагностический отчёт Athena\n"))
        XCTAssertFalse(text.contains("secret-version"))
        XCTAssertFalse(text.contains("/Users"))
    }
}

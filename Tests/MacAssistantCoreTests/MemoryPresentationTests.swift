import XCTest
@testable import MacAssistantCore
@testable import MacAssistant

final class MemoryPresentationTests: XCTestCase {
    private func row(_ pid: Int32, _ name: String, _ bytes: UInt64?, app: String? = nil) -> ProcessMemoryMetrics {
        ProcessMemoryMetrics(pid: pid, name: name, footprintBytes: .init(bytes), applicationID: app, applicationName: app == nil ? nil : "Application")
    }
    func testApplicationGroupIncludesHelperAndMarksPartialSum() throws {
        let rows = MemoryDisplayRow.make([row(1, "Main", 100, app: "a"), row(2, "Helper", 200, app: "a"),
            row(3, "Denied", nil, app: "a"), row(4, "Daemon", 50)], applications: true, search: "", sortByName: false)
        XCTAssertEqual(rows.count, 2)
        let app = try XCTUnwrap(rows.first)
        XCTAssertTrue(app.partial)
        XCTAssertEqual(app.bytes, 300); XCTAssertEqual(app.members, 3); XCTAssertEqual(app.unavailable, 1)
        XCTAssertNil(app.pid); XCTAssertEqual(rows.last?.pid, 4)
    }
    func testUngroupedProcessesSearchNameOrPIDAndKeepMeasuredZero() {
        let rows = [row(10, "Alpha", nil), row(20, "Beta", 0), row(30, "Gamma", 5)]
        XCTAssertEqual(MemoryDisplayRow.make(rows, applications: false, search: "", sortByName: false).map(\.pid), [30, 20, 10])
        XCTAssertEqual(MemoryDisplayRow.make(rows, applications: false, search: "ALP", sortByName: false).map(\.pid), [10])
        XCTAssertEqual(MemoryDisplayRow.make(rows, applications: false, search: "20", sortByName: false).map(\.pid), [20])
        XCTAssertEqual(MemoryDisplayRow.make(rows, applications: false, search: "", sortByName: true).map(\.pid), [10, 20, 30])
    }
    func testUnknownGroupAndOverflowNeverBecomeZero() {
        let unknown = MemoryDisplayRow.make([row(1, "Unknown", nil, app: "a")], applications: true, search: "", sortByName: false)
        XCTAssertNil(unknown.first?.bytes)
        let incomplete = MemoryDisplayRow.make([row(1, "Known", 100, app: "a")], applications: true,
            search: "", sortByName: false, coverageIncomplete: true)
        XCTAssertEqual(incomplete.first?.bytes, 100); XCTAssertEqual(incomplete.first?.partial, true)
        let overflow = MemoryDisplayRow.make([row(1, "Huge", .max, app: "a"), row(2, "Huge", 1, app: "a")], applications: true, search: "", sortByName: false)
        XCTAssertNil(overflow.first?.bytes)
        XCTAssertEqual(MemoryFormat.bytes(.max), "—"); XCTAssertNotEqual(MemoryFormat.bytes(0), "—")
    }
    func testByteUnitsFollowSelectedLanguageAndKeepBinaryMemoryScale() {
        XCTAssertEqual(MemoryFormat.bytes(1_073_741_824, language: .english), "1 GB")
        XCTAssertTrue(MemoryFormat.bytes(1_073_741_824, language: .russian).contains("ГБ"))
    }
    func testChartHasIndependentSeriesAndDoesNotConnectAcrossGaps() {
        let date = Date()
        let history = [MonitoringHistoryPoint(capturedAt: date, state: .available, values: ["used": 100, "swapUsed": 0]),
            MonitoringHistoryPoint(capturedAt: date.addingTimeInterval(1), state: .unavailable, values: [:]),
            MonitoringHistoryPoint(capturedAt: date.addingTimeInterval(2), state: .available, values: ["used": 200, "swapUsed": 10])]
        let points = MemoryChartPoint.make(history)
        let used = points.filter { $0.key == "used" }
        XCTAssertEqual(used.map(\.bytes), [100, 200]); XCTAssertNotEqual(used[0].segment, used[1].segment)
        XCTAssertEqual(points.filter { $0.key == "swapUsed" }.map(\.bytes), [0, 10])
        XCTAssertTrue(points.filter { $0.key == "compressed" }.isEmpty)
    }
    func testChartRejectsInvalidValuesAndReversedClock() {
        let date = Date()
        let points = MemoryChartPoint.make([
            MonitoringHistoryPoint(capturedAt: date, state: .available, values: ["used": 100]),
            MonitoringHistoryPoint(capturedAt: date.addingTimeInterval(-1), state: .available, values: ["used": 200]),
            MonitoringHistoryPoint(capturedAt: date, state: .available, values: ["used": .nan, "compressed": -1, "swapUsed": .infinity])])
        XCTAssertEqual(points.count, 2); XCTAssertNotEqual(points[0].segment, points[1].segment)
    }
}

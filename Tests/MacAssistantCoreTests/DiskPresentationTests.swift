import XCTest
@testable import MacAssistantCore
@testable import MacAssistant

@MainActor
final class DiskPresentationTests: XCTestCase {
    private func app(_ id: String, _ name: String, _ bytes: UInt64?, allocated: UInt64?) -> InstalledApplicationMetrics {
        .init(id: id, name: name, location: .shared, logicalBytes: .init(bytes), allocatedBytes: .init(allocated), complete: true)
    }
    func testApplicationSearchAndSizeSortKeepUnknownSeparateFromZero() {
        let rows = [app("a", "Alpha", nil, allocated: nil), app("b", "Beta", 0, allocated: 20), app("c", "Gamma", 100, allocated: 10)]
        XCTAssertEqual(DiskApplicationPresentation.rows(rows, search: "", sort: .logical).map(\.id), ["c", "b", "a"])
        XCTAssertEqual(DiskApplicationPresentation.rows(rows, search: "", sort: .allocated).map(\.id), ["b", "c", "a"])
        XCTAssertEqual(DiskApplicationPresentation.rows(rows, search: "", sort: .name).map(\.id), ["a", "b", "c"])
        XCTAssertEqual(DiskApplicationPresentation.rows(rows, search: "ALP", sort: .name).map(\.id), ["a"])
    }
    func testByteUnitsAndPartialSumsAreExplicit() {
        XCTAssertEqual(DiskFormat.bytes(1_000_000_000, language: .english), "1 GB")
        XCTAssertTrue(DiskFormat.bytes(1_000_000_000, language: .russian).contains("ГБ"))
        XCTAssertEqual(DiskFormat.bytes(0, language: .english, complete: false), "≥ 0 bytes")
        XCTAssertEqual(DiskFormat.bytes(nil, language: .english, complete: false), "—")
        XCTAssertEqual(DiskFormat.bytes(.max, language: .english), "—")
    }
    func testVolumeSelectionDefaultsToStartupAndSurvivesExistingManualSelection() {
        let model = DiskViewModel(provider: UnavailableLiveMonitoringService())
        let rows = [DiskVolumeMetrics(id: "external", totalBytes: .init(100), freeBytes: .init(50), mountPath: "/Volumes/Example"),
                    DiskVolumeMetrics(id: "startup", totalBytes: .init(100), freeBytes: .init(50), mountPath: "/")]
        func snapshot(_ rows: [DiskVolumeMetrics]) -> MonitoringSnapshot {
            .init(suspended: false, samples: [.init(group: .disk, capturedAt: Date(), intervalSeconds: 10, state: .available, payload: .disk(rows), stale: false)])
        }
        model.accept(snapshot: snapshot(rows)); XCTAssertEqual(model.selectedVolume, "startup")
        model.selectedVolume = "external"; model.accept(snapshot: snapshot(rows)); XCTAssertEqual(model.selectedVolume, "external")
        model.accept(snapshot: snapshot([rows[1]])); XCTAssertEqual(model.selectedVolume, "startup")
        model.accept(snapshot: snapshot([])); XCTAssertEqual(model.selectedVolume, "")
    }
    func testFreshCapacityDoesNotChangeInventoryCaptureTime() {
        let model = DiskViewModel(provider: UnavailableLiveMonitoringService()), date = Date(timeIntervalSince1970: 100)
        let inventory = ApplicationInventoryMetrics(capturedAt: date, applications: [], roots: [], discoveredApplications: 0,
            visitedEntries: 0, enumerationComplete: true, limitReached: false)
        model.accept(snapshot: .init(suspended: false, samples: [.init(group: .applications, capturedAt: date.addingTimeInterval(200),
            intervalSeconds: 300, state: .available, payload: .applications(inventory), stale: false)]))
        XCTAssertEqual(model.inventory?.capturedAt, date)
    }
}

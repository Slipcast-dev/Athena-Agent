import Foundation
import XCTest
@testable import MacAssistantCore

final class DiskCollectorTests: XCTestCase {
    func testLiveDiskMeasuresFreeSpaceSeparatelyFromImportantUsage() async throws {
        let coordinator = MonitoringCoordinator.makeLive()
        _ = try await coordinator.subscribe(groups: [.disk]); await coordinator.waitForCollections()
        let snapshot = await coordinator.snapshot()
        guard case .disk(let rows) = snapshot.samples.first(where: { $0.group == .disk })?.payload else {
            await coordinator.shutdown(); return XCTFail("Disk missing")
        }
        XCTAssertTrue(rows.contains { $0.freeBytes.value != nil }, "Free capacity must be measured, not replaced by important-usage")
        await coordinator.shutdown()
    }
    func testUsedCapacityIsTotalMinusFreeAndUnknownIsNotZero() {
        let value = DiskVolumeMetrics(id: "volume", totalBytes: .init(1000), freeBytes: .init(250), availableForImportantUsageBytes: .init(400))
        XCTAssertEqual(value.usedBytes.value, 750); XCTAssertEqual(value.availableForImportantUsageBytes.value, 400)
        XCTAssertNil(DiskVolumeMetrics(id: "volume", totalBytes: .init(1000), freeBytes: .init()).usedBytes.value)
        XCTAssertEqual(DiskVolumeMetrics(id: "volume", totalBytes: .init(1000), freeBytes: .init(0)).usedBytes.value, 1000)
    }
    func testInvalidCapacityAndOversizedMetadataAreRejected() {
        XCTAssertFalse(MonitoringPayload.disk([.init(id: "volume", totalBytes: .init(100), freeBytes: .init(200))]).validated())
        XCTAssertFalse(MonitoringPayload.disk([.init(id: "volume", totalBytes: .init(100), freeBytes: .init(20), mountPath: String(repeating: "a", count: 1025))]).validated())
    }
    func testNativeMountedVolumesHaveStableUniqueIDsAndMeasuredCapacity() throws {
        let rows = try MountedDiskVolumeReader().read()
        XCTAssertFalse(rows.isEmpty); XCTAssertLessThanOrEqual(rows.count, 32)
        XCTAssertEqual(Set(rows.map(\.id)).count, rows.count)
        XCTAssertTrue(rows.contains { $0.mountPath == "/" })
        for row in rows {
            XCTAssertFalse(row.id.contains("/"))
            if let total = row.totalBytes.value, let free = row.freeBytes.value {
                XCTAssertLessThanOrEqual(free, total); XCTAssertEqual(row.usedBytes.value, total - free)
            }
        }
    }
    func testLegacyDiskJSONStillDecodesWithoutNewMetadata() throws {
        let data = Data(#"{"disk":{"_0":[{"id":"system","totalBytes":{"state":"available","value":1000},"freeBytes":{"state":"unavailable"},"availableForImportantUsageBytes":{"state":"available","value":400}}]}}"#.utf8)
        let value = try JSONDecoder().decode(MonitoringPayload.self, from: data)
        XCTAssertTrue(value.validated())
        guard case .disk(let rows) = value else { return XCTFail("Wrong payload") }
        XCTAssertNil(rows.first?.name); XCTAssertNil(rows.first?.usedBytes.value)
    }

}

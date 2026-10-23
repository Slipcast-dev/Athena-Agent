import Darwin
import Foundation
import XCTest
@testable import MacAssistantCore

final class ApplicationInventoryTests: XCTestCase {
    private func fixture() throws -> URL {
        let root = URL(fileURLWithPath: "/private/tmp/athena-app-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        return root
    }
    private func scanner(_ root: URL, limits: ApplicationScanLimits = .init()) -> POSIXApplicationInventoryScanner {
        POSIXApplicationInventoryScanner(roots: [.init(url: root, location: .shared)], limits: limits)
    }
    func testNestedHelpersHardLinksAndExternalSymlinkAreNotDoubleCounted() async throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let apps = root.appendingPathComponent("Apps"), app = apps.appendingPathComponent("Utilities/Example.app")
        let helper = app.appendingPathComponent("Contents/Helper.app")
        try FileManager.default.createDirectory(at: helper, withIntermediateDirectories: true)
        let first = app.appendingPathComponent("first")
        try Data(repeating: 1, count: 10).write(to: first)
        try Data(repeating: 2, count: 25).write(to: app.appendingPathComponent("Contents/second"))
        try Data(repeating: 3, count: 7).write(to: helper.appendingPathComponent("third"))
        XCTAssertEqual(link(first.path, app.appendingPathComponent("hardlink").path), 0)
        let outside = root.appendingPathComponent("outside")
        try Data(repeating: 4, count: 100_000).write(to: outside)
        try FileManager.default.createSymbolicLink(at: app.appendingPathComponent("external-link"), withDestinationURL: outside)
        let result = try await scanner(apps).scan()
        XCTAssertEqual(result.applications.count, 1)
        let row = try XCTUnwrap(result.applications.first)
        XCTAssertEqual(row.name, "Example"); XCTAssertEqual(row.logicalBytes.value, 42)
        XCTAssertEqual(row.skippedSymbolicLinks, 1); XCTAssertTrue(row.complete)
        XCTAssertTrue(result.enumerationComplete); XCTAssertNotNil(row.allocatedBytes.value)
    }
    func testSparseFileKeepsLogicalSizeAbove32BitAndAllocatedSizeSeparate() async throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let app = root.appendingPathComponent("Sparse.app")
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: false)
        let file = app.appendingPathComponent("large")
        let fd = open(file.path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        XCTAssertGreaterThanOrEqual(fd, 0); defer { close(fd) }
        XCTAssertEqual(ftruncate(fd, 5_000_000_000), 0)
        let result = try await scanner(root).scan()
        let row = try XCTUnwrap(result.applications.first)
        XCTAssertEqual(row.logicalBytes.value, 5_000_000_000)
        XCTAssertLessThan(try XCTUnwrap(row.allocatedBytes.value), 5_000_000_000)
    }
    func testRootAndAncestorSymlinksAreRejectedAndDiscoveryLinksNotFollowed() async throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let apps = root.appendingPathComponent("real/Apps")
        try FileManager.default.createDirectory(at: apps.appendingPathComponent("Actual.app"), withIntermediateDirectories: true)
        let alias = root.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: root.appendingPathComponent("real"))
        for url in [alias, alias.appendingPathComponent("Apps")] {
            let result = try await scanner(url).scan()
            XCTAssertEqual(result.roots.first?.state, .symbolicLink); XCTAssertTrue(result.applications.isEmpty)
            XCTAssertFalse(result.enumerationComplete)
        }
        let discovery = root.appendingPathComponent("discovery")
        try FileManager.default.createDirectory(at: discovery, withIntermediateDirectories: false)
        try FileManager.default.createSymbolicLink(at: discovery.appendingPathComponent("Alias.app"), withDestinationURL: apps.appendingPathComponent("Actual.app"))
        let result = try await scanner(discovery).scan()
        XCTAssertTrue(result.applications.isEmpty); XCTAssertFalse(result.enumerationComplete)
    }
    func testEmptyBundleIsMeasuredZeroAndMissingRootIsExplicit() async throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Empty.app"), withIntermediateDirectories: false)
        let result = try await scanner(root).scan()
        XCTAssertEqual(result.applications.first?.logicalBytes.value, 0)
        XCTAssertTrue(result.applications.first?.complete == true)
        let missing = try await scanner(root.appendingPathComponent("missing")).scan()
        XCTAssertEqual(missing.roots.first?.state, .missing); XCTAssertTrue(missing.enumerationComplete)
    }
    func testUnreadableBundleAndRootDoNotBecomeMeasuredZero() async throws {
        guard getuid() != 0 else { throw XCTSkip("Permission fixture requires non-root") }
        let root = try fixture(); defer { chmod(root.path, 0o700); try? FileManager.default.removeItem(at: root) }
        let app = root.appendingPathComponent("Denied.app")
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: false)
        XCTAssertEqual(chmod(app.path, 0), 0); defer { chmod(app.path, 0o700) }
        let result = try await scanner(root).scan()
        XCTAssertFalse(result.applications.first?.complete ?? true)
        XCTAssertNil(result.applications.first?.logicalBytes.value)
        XCTAssertEqual(chmod(root.path, 0), 0)
        let denied = try await scanner(root).scan()
        XCTAssertEqual(denied.roots.first?.state, .inaccessible); XCTAssertFalse(denied.enumerationComplete)
    }
    func testEntryAndApplicationLimitsAreVisiblePartialResults() async throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        for index in 0..<3 {
            let app = root.appendingPathComponent("App\(index).app")
            try FileManager.default.createDirectory(at: app, withIntermediateDirectories: false)
            for file in 0..<4 { try Data(repeating: 1, count: 10).write(to: app.appendingPathComponent("f\(file)")) }
        }
        let apps = try await scanner(root, limits: .init(maximumApplications: 1)).scan()
        XCTAssertEqual(apps.applications.count, 1); XCTAssertTrue(apps.limitReached); XCTAssertFalse(apps.enumerationComplete)
        let entries = try await scanner(root, limits: .init(maximumEntries: 2)).scan()
        XCTAssertEqual(entries.visitedEntries, 2); XCTAssertTrue(entries.limitReached)
        XCTAssertFalse(entries.applications.first?.complete ?? true)
    }
    func testCooperativeTimeBudgetStopsWithoutInventingCompleteCatalogue() async throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Example.app"), withIntermediateDirectories: false)
        let clock = InventoryDeadlineClock()
        let result = try await POSIXApplicationInventoryScanner(roots: [.init(url: root, location: .shared)],
            limits: .init(maximumSeconds: 0.001), clock: clock.clock).scan()
        XCTAssertTrue(result.limitReached); XCTAssertFalse(result.enumerationComplete)
        XCTAssertEqual(result.visitedEntries, 0)
    }
    func testBundleDepthLimitIsAnExplicitPartialSize() async throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Deep.app/nested/deeper"), withIntermediateDirectories: true)
        let result = try await scanner(root, limits: .init(bundleDepth: 0)).scan()
        XCTAssertTrue(result.limitReached); XCTAssertFalse(result.applications.first?.complete ?? true)
    }
    func testCancellationStopsEvenBeforeReadingEmptyRoot() async throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await scanner(root).scan()
        }
        do { _ = try await task.value; XCTFail("Cancellation hidden") } catch is CancellationError {}
    }
    func testDuplicateRootsDoNotListBundleTwiceAndIDsAreOpaque() async throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Example.app"), withIntermediateDirectories: false)
        let source = POSIXApplicationInventoryScanner(roots: [.init(url: root, location: .shared), .init(url: root, location: .shared)])
        let result = try await source.scan()
        XCTAssertEqual(result.applications.count, 1); XCTAssertEqual(result.applications.first?.id.count, 64)
        let json = String(decoding: try JSONEncoder().encode(result), as: UTF8.self)
        XCTAssertFalse(json.contains(root.path)); XCTAssertTrue(MonitoringPayload.applications(result).validated())
    }
}

private final class InventoryDeadlineClock: @unchecked Sendable {
    private let lock = NSLock()
    private var tick: Double = 0
    var clock: MonitoringClock { MonitoringClock { self.now() } }
    private func now() -> MonitoringInstant {
        lock.lock(); defer { lock.unlock() }
        tick += 0.1
        return .init(monotonic: tick, date: Date(timeIntervalSince1970: 1_700_000_000 + tick))
    }
}

import XCTest
import EcosystemLocalIPC
@testable import MacAssistantCore
@testable import MacAssistant

/// Некoоперативный сервис проверяет fencing UI: поздний ответ не должен
/// возвращать результаты старой папки после отмены или нового выбора.
private actor FolderScanFixture: StorageAnalyzing {
    private var pending: [String: CheckedContinuation<[StorageItem], Error>] = [:]
    private var starts: [(URL, UInt64)] = []
    private var watchers: [(Int, CheckedContinuation<Void, Never>)] = []
    func storageOverview() async throws -> StorageOverview { .init(totalBytes: 100, availableBytes: 50) }
    func scanDirectory(at url: URL, minimumSizeBytes: UInt64) async throws -> [StorageItem] {
        try await withCheckedThrowingContinuation { continuation in
            pending[url.lastPathComponent] = continuation; starts.append((url, minimumSizeBytes))
            let ready = watchers.filter { $0.0 <= starts.count }
            watchers.removeAll { $0.0 <= starts.count }; ready.forEach { $0.1.resume() }
        }
    }
    func waitForStarts(_ count: Int) async {
        if starts.count >= count { return }
        await withCheckedContinuation { watchers.append((count, $0)) }
    }
    func count() -> Int { starts.count }
    func minimumSize() -> UInt64? { starts.last?.1 }
    func finish(_ name: String, failure: Bool = false) {
        guard let continuation = pending.removeValue(forKey: name) else { return }
        if failure { continuation.resume(throwing: LocalRuntimeFailure.unavailable) }
        else { continuation.resume(returning: [.init(url: URL(fileURLWithPath: "/fixture/\(name)/example.bin"), sizeBytes: 200_000_000, modifiedAt: nil, isDirectory: false)]) }
    }
}

@MainActor
final class FolderAnalysisTests: XCTestCase {
    private func settled(_ model: FolderAnalysisViewModel) async throws {
        for _ in 0..<200 {
            if model.state != .loading { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("Analysis UI did not settle")
    }
    func testOpeningAnalysisDoesNotScanUntilUserSelectsDirectory() async {
        let source = FolderScanFixture()
        let model = FolderAnalysisViewModel(storage: source)
        XCTAssertNil(model.selectedDirectory); XCTAssertTrue(model.items.isEmpty)
        let count = await source.count(); XCTAssertEqual(count, 0)
    }
    func testSelectedDirectoryUsesPreviousThresholdAndKeepsResults() async throws {
        let source = FolderScanFixture(), path = URL(fileURLWithPath: "/fixture/selected")
        let model = FolderAnalysisViewModel(storage: source)
        model.startScan(directory: path); await source.waitForStarts(1)
        let minimum = await source.minimumSize(); XCTAssertEqual(minimum, 100 * 1024 * 1024)
        await source.finish("selected"); try await settled(model)
        XCTAssertEqual(model.selectedDirectory, path); XCTAssertEqual(model.items.count, 1)
        XCTAssertFalse(model.cancelled); XCTAssertNil(model.runtimeError)
        model.cancel(); XCTAssertFalse(model.cancelled, "Completed result is retained when the sheet closes")
    }
    func testCancelledWaitRejectsLateResultAndDoesNotStayLoading() async throws {
        let source = FolderScanFixture(), modelPath = URL(fileURLWithPath: "/fixture/cancelled")
        let model = FolderAnalysisViewModel(storage: source)
        model.startScan(directory: modelPath); await source.waitForStarts(1)
        model.cancel(); XCTAssertEqual(model.state, .ready); XCTAssertTrue(model.cancelled)
        await source.finish("cancelled"); try await Task.sleep(for: .milliseconds(10))
        XCTAssertTrue(model.items.isEmpty); XCTAssertTrue(model.cancelled)
    }
    func testChangingFolderClearsOldRowsAndRejectsOldCompletion() async throws {
        let source = FolderScanFixture()
        let actual = FolderAnalysisViewModel(storage: source)
        actual.startScan(directory: URL(fileURLWithPath: "/fixture/one")); await source.waitForStarts(1)
        actual.startScan(directory: URL(fileURLWithPath: "/fixture/two")); await source.waitForStarts(2)
        XCTAssertTrue(actual.items.isEmpty)
        await source.finish("two"); try await settled(actual)
        await source.finish("one"); try await Task.sleep(for: .milliseconds(10))
        XCTAssertEqual(actual.items.first?.url.lastPathComponent, "example.bin")
        XCTAssertEqual(actual.items.first?.url.deletingLastPathComponent().lastPathComponent, "two")
    }
    func testFailureRemainsRecoverableAndNextSelectionClearsIt() async throws {
        let source = FolderScanFixture(), model = FolderAnalysisViewModel(storage: source)
        model.startScan(directory: URL(fileURLWithPath: "/fixture/broken")); await source.waitForStarts(1)
        await source.finish("broken", failure: true); try await settled(model)
        XCTAssertNotNil(model.runtimeError)
        model.startScan(directory: URL(fileURLWithPath: "/fixture/ok")); await source.waitForStarts(2)
        XCTAssertNil(model.runtimeError)
        await source.finish("ok"); try await settled(model)
        XCTAssertEqual(model.state, .ready); XCTAssertEqual(model.items.count, 1)
    }
}

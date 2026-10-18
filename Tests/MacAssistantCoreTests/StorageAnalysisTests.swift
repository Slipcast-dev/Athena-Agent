import XCTest
@testable import MacAssistantCore

final class StorageAnalysisTests: XCTestCase {
    func testValidatorRejectsNonexistentDirectory() {
        XCTAssertThrowsError(try StoragePathValidator.validatedDirectory(URL(fileURLWithPath: "/private/tmp/mac-assistant-missing"))) { error in
            XCTAssertEqual(error as? StorageAnalysisError, .invalidDirectory)
        }
    }

    func testValidatorRejectsSymbolicLinkChosenAsRootDirectory() throws {
        let target = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let link = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        defer {
            try? FileManager.default.removeItem(at: link)
            try? FileManager.default.removeItem(at: target)
        }

        XCTAssertThrowsError(try StoragePathValidator.validatedDirectory(link)) { error in
            XCTAssertEqual(error as? StorageAnalysisError, .invalidDirectory)
        }
    }

    func testScanFindsAndSortsLargeFilesWithoutFollowingSymlink() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let small = root.appendingPathComponent("small.bin")
        let large = root.appendingPathComponent("large.bin")
        try Data(repeating: 1, count: 10).write(to: small)
        try Data(repeating: 2, count: 100).write(to: large)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("outside-link"), withDestinationURL: FileManager.default.temporaryDirectory)

        let items = try await StorageAnalysisService().scanDirectory(at: root, minimumSizeBytes: 50)

        XCTAssertEqual(items.map(\.url.lastPathComponent), ["large.bin"])
        XCTAssertEqual(items.first?.sizeBytes, 100)
    }

    func testCancelledScanStopsBeforeProcessingDirectoryContents() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data(repeating: 1, count: 10).write(to: root.appendingPathComponent("file.bin"))
        let task = Task { try await StorageAnalysisService().scanDirectory(at: root, minimumSizeBytes: 0) }
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("Отменённое сканирование не должно возвращать результаты")
        } catch is CancellationError {
            // Ожидаемое завершение: сервис проверяет отмену в цикле перечисления.
        }
    }

    func testCancelledScanOfEmptyDirectoryStopsBeforeEnumeration() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let task = Task { try await StorageAnalysisService().scanDirectory(at: root, minimumSizeBytes: 0) }
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("Отменённое сканирование пустого каталога не должно возвращать результат")
        } catch is CancellationError {
            // Проверка отмены должна выполняться до обращения к файловому перечислителю.
        }
    }
}

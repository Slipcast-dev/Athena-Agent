import XCTest
@testable import MacAssistantCore

final class ArchitectureTests: XCTestCase {
    /// Явно переданные заглушки не должны подменять отсутствие реализации
    /// фиктивными метриками. Контейнер по умолчанию теперь использует локальный сервис.
    @MainActor
    func testUnavailableDependenciesReportUnavailableSystemInformation() async {
        let container = AppContainer(services: .unavailable)

        do {
            _ = try await container.services.systemInformation.systemInfo()
            XCTFail("Ожидалась явная ошибка отсутствующей реализации")
        } catch let error as ServiceError {
            XCTAssertEqual(error, .unavailable(feature: "Системная информация"))
        } catch {
            XCTFail("Получена неожиданная ошибка: \(error)")
        }
    }

    func testStorageUsageIsNilWhenTotalStorageIsZero() {
        let metrics = SystemMetrics(
            cpuUsagePercent: nil,
            totalMemoryBytes: 0,
            usedMemoryBytes: 0,
            availableMemoryBytes: nil,
            memoryPressure: nil,
            totalStorageBytes: 0,
            availableStorageBytes: 0
        )

        XCTAssertNil(metrics.storageUsagePercent)
    }

    func testStorageUsageUsesTotalAndAvailableBytes() {
        let metrics = SystemMetrics(
            cpuUsagePercent: nil,
            totalMemoryBytes: 0,
            usedMemoryBytes: 0,
            availableMemoryBytes: nil,
            memoryPressure: nil,
            totalStorageBytes: 1_000,
            availableStorageBytes: 250
        )

        XCTAssertEqual(metrics.storageUsagePercent, 75)
    }
}

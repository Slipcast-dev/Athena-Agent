import Foundation
import XCTest
import EcosystemLocalization
@testable import MacAssistantCore

/// Проверяются семантические коды, а не совпадения русского текста. Никакой
/// профиль клиента, сервис macOS или файловая база тестом не открываются.
final class TypedServiceErrorLocalizationTests: XCTestCase {
    func testAllBuiltinServiceCasesTranslateWithoutChangingLegacyDescription() {
        let ru = AgentLocalization(language: .russian)
        let en = AgentLocalization(language: .english)
        let pairs: [(ServiceError, ServiceError)] = ServiceFeature.allCases.map { feature -> (ServiceError, ServiceError) in
            (.unavailableFeature(feature), .unavailable(feature: feature.originalTitle))
        } + ServiceInputReason.allCases.map { reason -> (ServiceError, ServiceError) in
            (.invalidOperation(reason), .invalidInput(reason: reason.originalDescription))
        }
        XCTAssertEqual(pairs.count, 15)
        for (typed, legacy) in pairs {
            XCTAssertEqual(typed.errorDescription, legacy.errorDescription)
            XCTAssertEqual(ru.runtimeError(typed), legacy.errorDescription)
            let translated = en.runtimeError(typed)
            XCTAssertFalse(translated.contains("athena.service."))
            XCTAssertFalse(translated.contains("could not be completed"))
            XCTAssertFalse(translated.unicodeScalars.contains { (0x0400...0x04FF).contains($0.value) })
        }
    }

    func testLegacyAssociatedStringsAreNeverGuessedFromBuiltinText() {
        let en = AgentLocalization(language: .english)
        // Даже строка, совпадающая с нашим исходником, является внешним текстом,
        // пока caller не передал конечный код. Проценты не становятся шаблоном.
        let external = ServiceError.unavailable(feature: "Системная информация")
        XCTAssertTrue(en.runtimeError(external).contains("Системная информация"))
        XCTAssertFalse(en.runtimeError(ServiceError.unavailableFeature(.systemInformation)).contains("Системная информация"))
        let reason = ServiceError.invalidInput(reason: "Неизвестная команда. %@")
        XCTAssertTrue(en.runtimeError(reason).contains("Неизвестная команда. %@"))
        XCTAssertEqual(reason.errorDescription, "Некорректные входные данные: Неизвестная команда. %@")
    }

    func testTypedMissingSystemValuesTranslateWhileLegacyNamesRemainLiteral() {
        let ru = AgentLocalization(language: .russian)
        let en = AgentLocalization(language: .english)
        XCTAssertEqual(SystemValue.allCases.count, 2)
        for value in SystemValue.allCases {
            let typed = SystemServiceError.missingSystemValue(value)
            let legacy = SystemServiceError.missingValue(name: value.originalName)
            XCTAssertEqual(typed.errorDescription, legacy.errorDescription)
            XCTAssertEqual(ru.runtimeError(typed), legacy.errorDescription)
            let translated = en.runtimeError(typed)
            XCTAssertFalse(translated.contains("athena.system.value."))
            XCTAssertFalse(translated.contains("could not be completed"))
            XCTAssertFalse(translated.unicodeScalars.contains { (0x0400...0x04FF).contains($0.value) })
            XCTAssertTrue(en.runtimeError(legacy).contains(value.originalName))
        }
    }

    @MainActor
    func testUnavailableServicesActuallyThrowTypedBuiltinCases() async {
        let services = ServiceDependencies.unavailable
        do { _ = try await services.systemInformation.systemInfo(); XCTFail("Unavailable service succeeded") }
        catch { XCTAssertEqual(error as? ServiceError, .unavailableFeature(.systemInformation)) }
        do { _ = try await services.systemInformation.systemMetrics(); XCTFail("Unavailable service succeeded") }
        catch { XCTAssertEqual(error as? ServiceError, .unavailableFeature(.systemMetrics)) }
        do { _ = try await services.diagnostics.runDiagnostics(); XCTFail("Unavailable service succeeded") }
        catch { XCTAssertEqual(error as? ServiceError, .unavailableFeature(.diagnostics)) }
        do { _ = try await services.storage.storageOverview(); XCTFail("Unavailable service succeeded") }
        catch { XCTAssertEqual(error as? ServiceError, .unavailableFeature(.storageAnalysis)) }
    }
}

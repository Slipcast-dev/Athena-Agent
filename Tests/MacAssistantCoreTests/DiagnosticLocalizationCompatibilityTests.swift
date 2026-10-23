import Foundation
import XCTest
import EcosystemLocalization
@testable import MacAssistantCore

/// Новая metadata — только подсказка отображения; старые документы и читатели
/// должны сохранять прежний текст и identity, даже если семантика им неизвестна.
final class DiagnosticLocalizationCompatibilityTests: XCTestCase {
    private struct LegacyFinding: Codable, Equatable {
        let id: UUID
        let severity: DiagnosticSeverity
        let title: String
        let explanation: String
        let recommendation: String
    }
    private func original(code: String? = nil, version: Int? = nil,
                          severity: DiagnosticSeverity = .warning) -> DiagnosticFinding {
        DiagnosticFinding(severity: severity, title: "Личный заголовок %@",
            explanation: "Исходное пояснение", recommendation: "Исходная рекомендация",
            presentationCode: code, presentationVersion: version)
    }
    private func metrics(cpu: Double, storageAvailable: UInt64,
                         pressure: MemoryPressure) -> SystemMetrics {
        SystemMetrics(cpuUsagePercent: cpu, totalMemoryBytes: 1000,
            usedMemoryBytes: 500, availableMemoryBytes: 500, memoryPressure: pressure,
            totalStorageBytes: 1000, availableStorageBytes: storageAvailable)
    }

    func testLegacyJSONWithoutPresentationFieldsRemainsVerbatim() throws {
        let old = LegacyFinding(id: UUID(), severity: .warning, title: "Мало места на накопителе",
            explanation: "Legacy original %@", recommendation: "Do not rewrite")
        let bytes = try JSONEncoder().encode(old)
        let decoded = try JSONDecoder().decode(DiagnosticFinding.self, from: bytes)
        XCTAssertNil(decoded.presentationCode)
        XCTAssertNil(decoded.presentationVersion)
        XCTAssertNil(decoded.recognizedPresentationCode)
        for language in AgentLanguage.allCases {
            XCTAssertEqual(decoded.localized(using: AgentLocalization(language: language)), decoded)
        }
        XCTAssertEqual(try JSONDecoder().decode(LegacyFinding.self, from: JSONEncoder().encode(decoded)), old)
    }

    func testFactoryAllSevenCodesTranslateCopyAndRemainReadableByLegacyReader() throws {
        let samples = [metrics(cpu: 85, storageAvailable: 150, pressure: .warning),
                       metrics(cpu: 99, storageAvailable: 50, pressure: .critical),
                       metrics(cpu: 20, storageAvailable: 500, pressure: .normal)]
        let findings = samples.flatMap { DiagnosticFindingFactory.makeFindings(for: $0, thresholds: .init()) }
        XCTAssertEqual(Set(findings.compactMap(\.presentationCode)), Set(DiagnosticPresentationCode.allCases.map(\.rawValue)))
        for finding in findings {
            XCTAssertEqual(finding.presentationVersion, 1)
            XCTAssertEqual(finding.recognizedPresentationCode?.severity, finding.severity)
            let old = try JSONDecoder().decode(LegacyFinding.self, from: JSONEncoder().encode(finding))
            XCTAssertEqual(old.id, finding.id)
            XCTAssertEqual(old.title, finding.title)
            XCTAssertEqual(old.explanation, finding.explanation)
            XCTAssertEqual(old.recommendation, finding.recommendation)
            let ru = finding.localized(using: AgentLocalization(language: .russian))
            let en = finding.localized(using: AgentLocalization(language: .english))
            XCTAssertEqual(ru, finding) // Legacy RU fields stay byte-for-byte source text.
            XCTAssertEqual(en.id, finding.id)
            XCTAssertEqual(en.severity, finding.severity)
            XCTAssertEqual(en.presentationCode, finding.presentationCode)
            XCTAssertEqual(en.presentationVersion, finding.presentationVersion)
            for value in [en.title, en.explanation, en.recommendation] {
                XCTAssertFalse(value.isEmpty)
                XCTAssertFalse(value.contains("resource unavailable"))
                XCTAssertFalse(value.contains("athena.finding."))
                XCTAssertFalse(value.unicodeScalars.contains { (0x0400...0x04FF).contains($0.value) })
            }
        }
    }

    func testUnknownFutureAndMismatchedSeverityAlwaysKeepOriginalFields() {
        let rows = [original(code: "futureCode", version: 1),
                    original(code: "storageWarning", version: 2),
                    original(code: "storageWarning", version: nil),
                    original(code: nil, version: 1),
                    original(code: "storageWarning", version: 1, severity: .critical),
                    original(code: "noCriticalSigns", version: 1, severity: .warning)]
        for row in rows {
            XCTAssertNil(row.recognizedPresentationCode)
            for language in AgentLanguage.allCases {
                XCTAssertEqual(row.localized(using: AgentLocalization(language: language)), row)
            }
        }
    }

    func testRenderingDoesNotRewritePersistedReportHistoryOrMetrics() throws {
        let directory = URL(fileURLWithPath: "/private/tmp/athena-finding-localization-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                               attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let values = metrics(cpu: 99, storageAvailable: 50, pressure: .critical)
        let report = DiagnosticReport(applicationVersion: "fixture", operatingSystemVersion: "fixture",
            metrics: values, findings: DiagnosticFindingFactory.makeFindings(for: values, thresholds: .init()),
            status: .completed)
        let bytes = try JSONEncoder().encode([report])
        let file = directory.appendingPathComponent("history.json")
        try bytes.write(to: file)
        for language in AgentLanguage.allCases {
            let loaded = try JSONDecoder().decode([DiagnosticReport].self, from: Data(contentsOf: file))
            let display = loaded[0].findings.map { $0.localized(using: AgentLocalization(language: language)) }
            XCTAssertEqual(display.map(\.id), report.findings.map(\.id))
            XCTAssertEqual(loaded[0].id, report.id)
            XCTAssertEqual(loaded[0].metrics, report.metrics)
            XCTAssertEqual(try Data(contentsOf: file), bytes)
        }
    }

    func testTypedCoreErrorsTranslateOnlyKnownEnvelopeAndKeepArgumentsLiteral() {
        let en = AgentLocalization(language: .english)
        let errors: [any RuntimeLocalizedError] = [
            ServiceError.unavailable(feature: "External %@ feature"),
            ServiceError.invalidInput(reason: "External reason %@"),
            SystemServiceError.sysctlFailed(name: "hw.fixture", code: 5),
            SystemServiceError.machCallFailed(code: 5), SystemServiceError.missingValue(name: "hw.fixture"),
            StorageAnalysisError.invalidDirectory, StorageAnalysisError.cannotEnumerateDirectory,
            StorageAnalysisError.volumeInformationUnavailable,
            MCPConnectionError.codexRegistrationFailed(message: ""),
            MCPConnectionError.codexRegistrationFailed(message: "External failure %@"),
            AIProviderError.invalidEndpoint, AIProviderError.insecureEndpoint,
            AIProviderError.insecureLocalEndpoint, AIProviderError.secretStorageFailed,
            AIProviderError.missingAPIKey, AIProviderError.unauthorized, AIProviderError.rateLimited,
            AIProviderError.server(status: 503), AIProviderError.invalidResponse, AIProviderError.network
        ]
        for error in errors {
            let text = en.runtimeMessage(error.runtimeMessage)
            XCTAssertFalse(text.isEmpty)
            XCTAssertFalse(text.contains("resource unavailable"))
            XCTAssertFalse(text.contains("athena.error."))
            XCTAssertFalse(text.unicodeScalars.contains { (0x0400...0x04FF).contains($0.value) })
        }
        XCTAssertTrue(en.runtimeMessage(ServiceError.invalidInput(reason: "External reason %@").runtimeMessage)
            .contains("External reason %@"))
        XCTAssertFalse(en.runtimeMessage(MCPConnectionError.codexRegistrationFailed(message: "External failure %@ SECRET_TOKEN").runtimeMessage)
            .contains("SECRET_TOKEN"))
        // Исходный LocalizedError нужен legacy consumers и остаётся прежним.
        XCTAssertEqual(StorageAnalysisError.invalidDirectory.errorDescription, "Выберите существующий каталог для анализа.")
    }
}

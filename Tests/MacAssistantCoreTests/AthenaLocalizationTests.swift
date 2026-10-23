import Foundation
import XCTest
import MacAssistantCore
import EcosystemLocalization
import EcosystemUI
@testable import MacAssistant

/// Детерминированный источник не читает текущий Mac: проверяем отсутствие
/// дополнительных запросов датчиков из самого преобразования текста.
actor LanguageSystemFixture: SystemInformationProviding {
    private(set) var calls = 0
    let metrics: SystemMetrics
    init(metrics: SystemMetrics) { self.metrics = metrics }
    func systemInfo() async throws -> SystemInfo {
        calls += 1
        return SystemInfo(modelName: "Example Mac", operatingSystemVersion: "macOS fixture", architecture: "arm64", physicalCPUCoreCount: 4, logicalCPUCoreCount: 8)
    }
    func systemMetrics() async throws -> SystemMetrics { calls += 1; return metrics }
}

@MainActor final class AthenaLocalizationTests: XCTestCase {
    private let ru = AthenaLocalization(language: .russian)
    private let en = AthenaLocalization(language: .english)
    static func metrics(cpu: Double? = 20, state: MeasurementState? = .available, capturedAt: Date = Date()) -> SystemMetrics {
        SystemMetrics(capturedAt: capturedAt, cpuState: state, cpuUsagePercent: cpu,
            totalMemoryBytes: 16_000_000_000, usedMemoryBytes: 4_000_000_000, availableMemoryBytes: 12_000_000_000,
            memoryPressure: nil, totalStorageBytes: 1_000_000_000_000, availableStorageBytes: 300_000_000_000)
    }
    func testResourcesHaveParityAndEveryTemplateRenders() throws {
        let base = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/MacAssistant/Resources")
        func read(_ language: String) throws -> [String: String] {
            try XCTUnwrap(PropertyListSerialization.propertyList(from: Data(contentsOf: base.appendingPathComponent(language + ".lproj/Athena.strings")), format: nil) as? [String: String])
        }
        let russian = try read("ru"), english = try read("en")
        XCTAssertEqual(Set(russian.keys), Set(english.keys)); XCTAssertGreaterThan(russian.count, 100)
        for key in russian.keys {
            let count = key.components(separatedBy: "%@").count - 1
            let translated = try XCTUnwrap(english[key])
            XCTAssertEqual(count, translated.components(separatedBy: "%@").count - 1, key)
            XCTAssertNil(translated.range(of: "[А-Яа-яЁё]", options: .regularExpression), key)
            for l10n in [ru, en] {
                let text = l10n.render(AthenaMessage(key, args: Array(repeating: "Example%@100%", count: count)))
                XCTAssertFalse(text.isEmpty); XCTAssertNotEqual(text, AthenaLocalization.unavailable, key)
                if count > 0 { XCTAssertTrue(text.contains("Example%@100%")) }
            }
        }
    }
    func testExternalTextAndPercentAreNeverInterpretedAsKeys() {
        let user = "Обзор / %@ 100%"
        XCTAssertEqual(en.render(.verbatim(user)), user)
        XCTAssertEqual(en.format("%@ из %@", user, "data"), user + " of data")
        XCTAssertEqual(en.text("%@ из %@"), AthenaLocalization.unavailable)
        XCTAssertEqual(en.text("missing-user-key"), AthenaLocalization.unavailable)
        let frozen = ConfirmationLanguage(language: .russian)
        XCTAssertEqual(AthenaLocalization(language: frozen.language).text("Обзор"), "Обзор")
        XCTAssertEqual(en.text("Обзор"), "Overview")
    }
    func testNavigationMonitorAndAppearanceIdentifiersRemainStable() {
        XCTAssertEqual(AppSection.allCases.map(\.rawValue), ["dashboard", "diagnostics", "storage", "settings"])
        XCTAssertEqual(AppAppearance.allCases.map(\.rawValue), ["system", "light", "dark"])
        XCTAssertEqual(AppSection.allCases.map { en.text($0.title) }, ["Overview", "Diagnostics", "Storage", "Settings"])
        XCTAssertEqual(MonitorMetric.allCases.map(\.rawValue), ["cpu", "storage", "memoryPressure"])
        let statuses: [MonitorStatus] = [.normal, .warmingUp, .warning, .critical, .recovered, .unavailable]
        XCTAssertEqual(Set(statuses.map { en.text(MonitorPresentation.statusTitle($0)) }).count, statuses.count)
        for metric in MonitorMetric.allCases { XCTAssertNotEqual(en.text(MonitorViewModel.metricTitle(metric)), AthenaLocalization.unavailable) }
    }
    func testMeasurementQualityDoesNotTurnMissingOrStaleDataIntoNormal() {
        let warming = Self.metrics(cpu: nil, state: .warmingUp)
        let unavailable = Self.metrics(cpu: nil, state: .unavailable)
        let unsupported = Self.metrics(cpu: nil, state: .unsupported)
        XCTAssertEqual(AthenaMetricPresentation.cpu(warming, using: en), "Collecting measurements")
        XCTAssertEqual(AthenaMetricPresentation.cpu(unavailable, using: en), "Measurement unavailable")
        XCTAssertEqual(AthenaMetricPresentation.cpu(unsupported, using: en), "Measurement unsupported")
        XCTAssertEqual(AthenaMetricPresentation.cpu(Self.metrics(cpu: .nan), using: en), "Measurement unavailable")
        let now = Date(), stale = Self.metrics(capturedAt: Date().addingTimeInterval(-121))
        XCTAssertTrue(AthenaMetricPresentation.freshness(stale, now: now, using: en).hasPrefix("Metrics are stale."))
        XCTAssertTrue(AthenaMetricPresentation.freshness(Self.metrics(capturedAt: now), now: now, using: en).hasPrefix("Updated: "))
        XCTAssertTrue(stale.quality(now: now).stale)
    }
    func testLanguageRenderingDoesNotPollSensorsOrMutateSnapshot() async throws {
        let metrics = Self.metrics(), fixture = LanguageSystemFixture(metrics: Self.metrics())
        let model = DashboardViewModel(systemInformation: fixture)
        await model.refresh()
        let before = await fixture.calls
        for l10n in [ru, en, ru, en] {
            _ = AthenaMetricPresentation.cpu(metrics, using: l10n)
            _ = AthenaMetricPresentation.freshness(metrics, now: metrics.capturedAt, using: l10n)
        }
        let after = await fixture.calls
        XCTAssertEqual(after, before); XCTAssertEqual(before, 2)
        XCTAssertEqual(metrics.cpuUsagePercent, 20)
    }
    func testDiagnosticsAndRealStorageScanPreserveResultsAcrossLanguages() async throws {
        let system = LanguageSystemFixture(metrics: Self.metrics(cpu: nil, state: .warmingUp))
        let diagnostics = DiagnosticsViewModel(diagnostics: SystemDiagnosticsService(systemInformation: system))
        await diagnostics.run()
        let original = try XCTUnwrap(diagnostics.report)
        XCTAssertEqual(original.status, .partial)
        for l10n in [ru, en] {
            XCTAssertNotEqual(l10n.text("Часть измерений недоступна или подготавливается"), AthenaLocalization.unavailable)
            for finding in original.findings { XCTAssertEqual(l10n.render(.verbatim(finding.explanation)), finding.explanation) }
        }
        XCTAssertEqual(diagnostics.report, original)
        let base = URL(fileURLWithPath: "/private/tmp/athena-l10n-storage-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: base) }
        let file = base.appendingPathComponent("Обзор %@.bin")
        XCTAssertTrue(FileManager.default.createFile(atPath: file.path, contents: nil))
        let handle = try FileHandle(forWritingTo: file)
        // Sparse-файл даёт реальный stat большого файла без заполнения диска.
        try handle.truncate(atOffset: 105_000_000); try handle.close()
        let storage = StorageViewModel(storage: StorageAnalysisService())
        storage.startScan(directory: base)
        for _ in 0..<300 where storage.state == .loading { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(storage.state, .ready); XCTAssertEqual(storage.items.count, 1)
        let result = try XCTUnwrap(storage.items.first)
        XCTAssertEqual(result.url, file); XCTAssertEqual(result.sizeBytes, 105_000_000)
        for l10n in [ru, en] { XCTAssertEqual(l10n.render(.verbatim(result.url.lastPathComponent)), "Обзор %@.bin") }
        XCTAssertEqual(storage.items.first, result)
    }
}

import AppKit
import SwiftUI
import XCTest
import EcosystemLocalization
import EcosystemLocalIPC
@testable import MacAssistantCore
@testable import MacAssistant

@MainActor
final class ProcessorScreenTests: XCTestCase {
    private func model(core: Int? = nil, state: MeasurementState = .available, stale: Bool = false, stopped: Bool = false) -> ProcessorViewModel {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let fields: [MonitoringMetric<Double>] = (0..<8).map { index in
            state == .available ? .init(Double(10 + index * 10)) : .init(state: state)
        }
        let data = CPUMonitoringMetrics(totalPercent: state == .available ? .init(42) : .init(state: state),
            userPercent: state == .available ? .init(30) : .init(state: state),
            systemPercent: state == .available ? .init(12) : .init(state: state), cores: fields,
            identity: ProcessorIdentity(name: "Apple CPU — Preview", physicalCoreCount: 8, logicalCoreCount: 8,
                                        performanceCoreCount: 4, efficiencyCoreCount: 4))
        let sample = MonitoringSample(group: .cpu, capturedAt: date, intervalSeconds: 1, state: state, payload: .cpu(data), stale: stale)
        let rows = (0..<60).map { index -> MonitoringHistoryPoint in
            var values = ["total": 40 + sin(Double(index) / 5) * 12, "user": 30 + sin(Double(index) / 5) * 9,
                          "system": 10 + sin(Double(index) / 5) * 3]
            for core in 0..<8 { values["core.\(core)"] = Double(10 + core * 10) + sin(Double(index) / 5) * 8 }
            return MonitoringHistoryPoint(capturedAt: date.addingTimeInterval(Double(index - 59)),
                state: index == 28 ? .warmingUp : state, values: index == 28 || state != .available ? [:] : values)
        }
        let model = ProcessorViewModel(provider: UnavailableLiveMonitoringService())
        model.accept(snapshot: MonitoringSnapshot(suspended: stopped, samples: [sample]), history: rows)
        model.selectedCore = core
        return model
    }

    private func render(_ model: ProcessorViewModel, width: CGFloat, language: AgentLanguage,
                        theme: ColorScheme, suffix: String) async throws {
        let root = ProcessorContent(model: model).environment(\.agentLanguage, language)
            .environment(\.colorScheme, theme).frame(width: width, height: 900)
            .background(Color(nsColor: .windowBackgroundColor))
        let host = NSHostingView(rootView: root)
        host.frame = NSRect(x: 0, y: 0, width: width, height: 900)
        let window = NSWindow(contentRect: host.bounds, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host
        window.appearance = NSAppearance(named: theme == .light ? .aqua : .darkAqua)
        host.appearance = window.appearance
        window.orderFrontRegardless(); window.displayIfNeeded()
        defer { window.close() }
        try await Task.sleep(for: .milliseconds(150))
        host.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        window.appearance?.performAsCurrentDrawingAppearance { host.cacheDisplay(in: host.bounds, to: bitmap) }
        XCTAssertGreaterThanOrEqual(bitmap.pixelsWide, Int(width))
        var colors = Set<String>()
        for y in stride(from: 0, to: bitmap.pixelsHigh, by: 8) {
            for x in stride(from: 0, to: bitmap.pixelsWide, by: 8) {
                if let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) {
                    colors.insert("\(Int(color.redComponent * 255)),\(Int(color.greenComponent * 255)),\(Int(color.blueComponent * 255))")
                }
            }
        }
        XCTAssertGreaterThan(colors.count, 60, "Chart/text must actually render")
        if let path = ProcessInfo.processInfo.environment["ATHENA_PROCESSOR_SCREENSHOTS_DIR"] {
            let directory = URL(fileURLWithPath: path)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let file = directory.appendingPathComponent("processor-\(language.rawValue)-\(theme == .light ? "light" : "dark")-\(Int(width))-\(suffix).png")
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: file)
        }
    }

    func testProcessorRendersBothThemesLanguagesAndCompactWideLayouts() async throws {
        for language in AgentLanguage.allCases {
            for theme in [ColorScheme.light, .dark] {
                for width: CGFloat in [520, 1000] {
                    try await render(model(), width: width, language: language, theme: theme, suffix: "total")
                }
            }
        }
    }
    func testSelectedCoreWarmingStaleAndEmergencyScreensRender() async throws {
        try await render(model(core: 3), width: 660, language: .russian, theme: .dark, suffix: "core4")
        try await render(model(state: .warmingUp), width: 520, language: .english, theme: .light, suffix: "warming")
        try await render(model(stale: true), width: 520, language: .russian, theme: .light, suffix: "stale")
        try await render(model(stopped: true), width: 520, language: .english, theme: .dark, suffix: "stopped")
    }
    func testNewNavigationAndLocalizedLabelsHaveCompleteCatalogues() {
        for language in AgentLanguage.allCases {
            let l10n = AthenaLocalization(language: language)
            XCTAssertNotEqual(l10n.text(AppSection.processor.title), AthenaLocalization.unavailable)
            for window in ProcessorHistoryWindow.allCases { XCTAssertNotEqual(l10n.text(window.title), AthenaLocalization.unavailable) }
            for series in ProcessorSeries.allCases { XCTAssertNotEqual(l10n.text(series.title), AthenaLocalization.unavailable) }
            XCTAssertTrue(l10n.format("Ядро %@", "8").contains("8"))
            XCTAssertEqual(SidebarView.destination(from: .processor, direction: .down), .network)
        }
    }
}

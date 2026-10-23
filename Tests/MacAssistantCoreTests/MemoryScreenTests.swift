import AppKit
import SwiftUI
import XCTest
import EcosystemLocalization
import EcosystemLocalIPC
@testable import MacAssistantCore
@testable import MacAssistant

@MainActor
final class MemoryScreenTests: XCTestCase {
    private func model(state: MeasurementState = .available, stale: Bool = false, stopped: Bool = false) -> MemoryViewModel {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let data = MemoryMonitoringMetrics(totalBytes: .init(16 * 1_073_741_824), usedBytes: .init(10 * 1_073_741_824),
            availableBytes: .init(6 * 1_073_741_824), wiredBytes: .init(2 * 1_073_741_824), compressedBytes: .init(1_073_741_824),
            cachedBytes: .init(3 * 1_073_741_824), swapUsedBytes: .init(536_870_912), pressure: .init(.normal))
        let sample = MonitoringSample(group: .memory, capturedAt: date, intervalSeconds: 1, state: state,
                                      payload: state == .available ? .memory(data) : nil, stale: stale)
        let processes: [ProcessMemoryMetrics] = (1...20).map { index in
            let footprint: MonitoringMetric<UInt64> = index == 2 ? .init() : .init(UInt64(index) * 25_000_000)
            let appID: String? = index <= 3 ? "preview-app" : nil
            let appName: String? = index <= 3 ? "Example App — Preview" : nil
            return ProcessMemoryMetrics(pid: Int32(index), name: "Preview \(index)", footprintBytes: footprint,
                                        applicationID: appID, applicationName: appName)
        }
        let processSample = MonitoringSample(group: .processes, capturedAt: date, intervalSeconds: 5, state: state,
            payload: state == .available ? .processes(processes, summary: .init(observed: 20, readable: 19, unavailable: 1, omitted: 0, enumerationComplete: true)) : nil, stale: stale)
        let rows: [MonitoringHistoryPoint] = (0..<60).map { index in
            let values: [String: Double] = ["used": 10_737_418_240 + sin(Double(index) / 5) * 500_000_000,
                                            "compressed": 1_073_741_824, "swapUsed": 536_870_912]
            return MonitoringHistoryPoint(capturedAt: date.addingTimeInterval(Double(index - 59)),
                state: index == 28 ? .warmingUp : state,
                values: index == 28 || state != .available ? [:] : values)
        }
        let model = MemoryViewModel(provider: UnavailableLiveMonitoringService())
        model.accept(snapshot: MonitoringSnapshot(suspended: stopped, samples: [sample, processSample]), history: rows)
        return model
    }

    private func render(_ model: MemoryViewModel, width: CGFloat, language: AgentLanguage,
                        theme: ColorScheme, suffix: String) async throws {
        let root = MemoryContent(model: model).environment(\.agentLanguage, language)
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
        if let path = ProcessInfo.processInfo.environment["ATHENA_MEMORY_SCREENSHOTS_DIR"] {
            let directory = URL(fileURLWithPath: path)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let file = directory.appendingPathComponent("memory-\(language.rawValue)-\(theme == .light ? "light" : "dark")-\(Int(width))-\(suffix).png")
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: file)
        }
    }

    func testMemoryRendersBothThemesLanguagesAndCompactWideLayouts() async throws {
        for language in AgentLanguage.allCases {
            for theme in [ColorScheme.light, .dark] {
                for width: CGFloat in [520, 1000] {
                    try await render(model(), width: width, language: language, theme: theme, suffix: "total")
                }
            }
        }
    }
    func testUnavailableStaleAndEmergencyScreensRender() async throws {
        try await render(model(state: .unavailable), width: 520, language: .english, theme: .light, suffix: "unavailable")
        try await render(model(stale: true), width: 520, language: .russian, theme: .light, suffix: "stale")
        try await render(model(stopped: true), width: 520, language: .english, theme: .dark, suffix: "stopped")
    }
    func testNewNavigationAndLocalizedLabelsHaveCompleteCatalogues() {
        for language in AgentLanguage.allCases {
            let l10n = AthenaLocalization(language: language)
            XCTAssertNotEqual(l10n.text(AppSection.memory.title), AthenaLocalization.unavailable)
            XCTAssertTrue(l10n.format("Процессов: %@", "3").contains("3"))
        }
        XCTAssertEqual(SidebarView.destination(from: .processor, direction: .down), .network)
        XCTAssertEqual(SidebarView.destination(from: .memory, direction: .down), .battery)
        XCTAssertEqual(model().rows.first(where: { $0.id == "app.preview-app" })?.unavailable, 1)
    }
}

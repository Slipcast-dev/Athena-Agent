import AppKit
import SwiftUI
import XCTest
import EcosystemLocalization
import EcosystemLocalIPC
@testable import MacAssistantCore
@testable import MacAssistant

@MainActor
final class DiskScreenTests: XCTestCase {
    private func model(state: MeasurementState = .available, stale: Bool = false, stopped: Bool = false, partial: Bool = false) -> DiskViewModel {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let volume = DiskVolumeMetrics(id: "startup", totalBytes: .init(500_000_000_000), freeBytes: .init(200_000_000_000),
            availableForImportantUsageBytes: .init(250_000_000_000), name: "Example Disk — Preview", mountPath: "/", readOnly: false)
        let rows = [InstalledApplicationMetrics(id: String(repeating: "a", count: 64), name: "Example Editor — Preview", location: .shared,
            logicalBytes: .init(1_500_000_000), allocatedBytes: .init(1_000_000_000), complete: true),
            InstalledApplicationMetrics(id: String(repeating: "b", count: 64), name: "Example Utility — Preview", location: .system,
                logicalBytes: .init(400_000_000), allocatedBytes: .init(200_000_000), complete: !partial, inaccessibleEntries: partial ? 1 : 0)]
        let inventory = ApplicationInventoryMetrics(capturedAt: date, applications: rows,
            roots: [.init(location: .shared, state: .readable), .init(location: .system, state: .readable), .init(location: .user, state: .missing)],
            discoveredApplications: 2, visitedEntries: 1200, enumerationComplete: !partial, limitReached: partial)
        let samples = [MonitoringSample(group: .disk, capturedAt: date, intervalSeconds: 10, state: state, payload: .disk([volume]), stale: stale),
            MonitoringSample(group: .applications, capturedAt: date, intervalSeconds: 300, state: state,
                payload: state == .warmingUp ? nil : .applications(inventory), stale: stale)]
        let model = DiskViewModel(provider: UnavailableLiveMonitoringService())
        model.accept(snapshot: MonitoringSnapshot(suspended: stopped, samples: samples))
        return model
    }

    private func render(_ model: DiskViewModel, width: CGFloat, language: AgentLanguage,
                        theme: ColorScheme, suffix: String) async throws {
        let root = DiskContent(model: model).environment(\.agentLanguage, language)
            .environment(\.colorScheme, theme).frame(width: width, height: 1400)
            .background(Color(nsColor: .windowBackgroundColor))
        let host = NSHostingView(rootView: root)
        host.frame = NSRect(x: 0, y: 0, width: width, height: 1400)
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
        if let path = ProcessInfo.processInfo.environment["ATHENA_DISK_SCREENSHOTS_DIR"] {
            let directory = URL(fileURLWithPath: path)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let file = directory.appendingPathComponent("disk-\(language.rawValue)-\(theme == .light ? "light" : "dark")-\(Int(width))-\(suffix).png")
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: file)
        }
    }

    func testDiskRendersBothThemesLanguagesAndCompactWideLayouts() async throws {
        for language in AgentLanguage.allCases {
            for theme in [ColorScheme.light, .dark] {
                for width: CGFloat in [520, 1000] {
                    try await render(model(), width: width, language: language, theme: theme, suffix: "total")
                }
            }
        }
    }
    func testUnavailableStaleAndEmergencyScreensRender() async throws {
        try await render(model(partial: true), width: 520, language: .russian, theme: .dark, suffix: "partial")
        try await render(model(state: .warmingUp), width: 520, language: .english, theme: .light, suffix: "unavailable")
        try await render(model(stale: true), width: 520, language: .russian, theme: .light, suffix: "stale")
        try await render(model(stopped: true), width: 520, language: .english, theme: .dark, suffix: "stopped")
    }
    func testNewNavigationAndLocalizedLabelsHaveCompleteCatalogues() {
        for language in AgentLanguage.allCases {
            let l10n = AthenaLocalization(language: language)
            XCTAssertNotEqual(l10n.text(AppSection.disk.title), AthenaLocalization.unavailable)
            XCTAssertNotEqual(l10n.text("Установленные приложения"), AthenaLocalization.unavailable)
        }
        XCTAssertEqual(SidebarView.destination(from: .disk, direction: .down), .memory)
        XCTAssertEqual(SidebarView.destination(from: .memory, direction: .down), .battery)
        XCTAssertEqual(SidebarView.destination(from: .network, direction: .down), .disk)
    }
}

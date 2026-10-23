import AppKit
import SwiftUI
import XCTest
import EcosystemLocalization
import EcosystemLocalIPC
@testable import MacAssistantCore
@testable import MacAssistant

@MainActor
final class BatteryScreenTests: XCTestCase {
    private func model(state: MeasurementState = .available, stale: Bool = false, stopped: Bool = false, absent: Bool = false) -> BatteryViewModel {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        var details = BatteryMonitoringDetails()
        details.powerSource = .init(.battery); details.health = .init(.good)
        details.fullyCharged = .init(false); details.minutesToEmpty = .init(180)
        details.voltageVolts = .init(12.3); details.currentAmperes = .init(-1.7)
        details.retainedCapacityPercent = .init(91)
        let data = absent ? BatteryMonitoringMetrics(present: .init(false)) : BatteryMonitoringMetrics(
            present: .init(true), chargePercent: .init(72), charging: .init(false), cycleCount: .init(155), temperatureCelsius: .init(31), details: details)
        let sample = MonitoringSample(group: .battery, capturedAt: date, intervalSeconds: 15, state: state,
            payload: state == .available ? .battery(data) : nil, stale: stale)
        let history = (0..<40).map { index in MonitoringHistoryPoint(capturedAt: date.addingTimeInterval(Double(index - 39) * 15),
            state: .available, values: ["charge": 73 - Double(index) / 39]) }
        let model = BatteryViewModel(provider: UnavailableLiveMonitoringService())
        model.historyWindow = .fifteenMinutes
        model.accept(snapshot: MonitoringSnapshot(suspended: stopped, samples: [sample]), history: state == .available ? history : [])
        return model
    }

    private func render(_ model: BatteryViewModel, width: CGFloat, language: AgentLanguage,
                        theme: ColorScheme, suffix: String) async throws {
        let root = BatteryContent(model: model).environment(\.agentLanguage, language)
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
        if let path = ProcessInfo.processInfo.environment["ATHENA_BATTERY_SCREENSHOTS_DIR"] {
            let directory = URL(fileURLWithPath: path)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let file = directory.appendingPathComponent("battery-\(language.rawValue)-\(theme == .light ? "light" : "dark")-\(Int(width))-\(suffix).png")
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: file)
        }
    }

    func testBatteryRendersBothThemesLanguagesAndCompactWideLayouts() async throws {
        for language in AgentLanguage.allCases {
            for theme in [ColorScheme.light, .dark] {
                for width: CGFloat in [520, 1000] {
                    try await render(model(), width: width, language: language, theme: theme, suffix: "total")
                }
            }
        }
    }
    func testUnavailableStaleAndEmergencyScreensRender() async throws {
        try await render(model(absent: true), width: 520, language: .russian, theme: .dark, suffix: "absent")
        try await render(model(state: .warmingUp), width: 520, language: .english, theme: .light, suffix: "unavailable")
        try await render(model(stale: true), width: 520, language: .russian, theme: .light, suffix: "stale")
        try await render(model(stopped: true), width: 520, language: .english, theme: .dark, suffix: "stopped")
    }
    func testNewNavigationAndLocalizedLabelsHaveCompleteCatalogues() {
        for language in AgentLanguage.allCases {
            let l10n = AthenaLocalization(language: language)
            XCTAssertNotEqual(l10n.text(AppSection.battery.title), AthenaLocalization.unavailable)
            XCTAssertNotEqual(l10n.text("График заряда аккумулятора"), AthenaLocalization.unavailable)
        }
        XCTAssertEqual(SidebarView.destination(from: .memory, direction: .down), .battery)
        XCTAssertEqual(SidebarView.destination(from: .battery, direction: .down), .diagnostics)
    }
    func testGraphBreaksAtMissingInvalidAndReverseTime() {
        let start = Date(timeIntervalSince1970: 1000)
        let history: [MonitoringHistoryPoint] = [
            .init(capturedAt: start, state: .available, values: ["charge": 50]),
            .init(capturedAt: start.addingTimeInterval(15), state: .unavailable, values: [:]),
            .init(capturedAt: start.addingTimeInterval(30), state: .available, values: ["charge": 49]),
            .init(capturedAt: start.addingTimeInterval(20), state: .available, values: ["charge": 48]),
            .init(capturedAt: start.addingTimeInterval(90), state: .available, values: ["charge": 47]),
            .init(capturedAt: start.addingTimeInterval(105), state: .available, values: ["charge": 101])]
        let points = BatteryChartPoint.make(history)
        XCTAssertEqual(points.count, 4); XCTAssertEqual(Set(points.map(\.segment)).count, 4)
        XCTAssertEqual(BatteryFormat.number(nil, language: .russian), "—")
        XCTAssertEqual(BatteryFormat.number(0, language: .english, suffix: "%"), "0%")
        XCTAssertEqual(BatteryFormat.minutes(.init(nil, state: .warmingUp), using: .init(language: .english)), "Calculating time")
        XCTAssertEqual(BatteryFormat.minutes(.init(180), using: .init(language: .russian)), "180 мин")
        XCTAssertEqual(BatteryFormat.minutes(.init(180), using: .init(language: .english)), "180 min")
    }
}

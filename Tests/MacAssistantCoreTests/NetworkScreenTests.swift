import AppKit
import SwiftUI
import XCTest
import EcosystemLocalization
import EcosystemLocalIPC
@testable import MacAssistantCore
@testable import MacAssistant

@MainActor
final class NetworkScreenTests: XCTestCase {
    private func model(state: MeasurementState = .available, stale: Bool = false, stopped: Bool = false, up: Bool = true) -> NetworkViewModel {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let details = NetworkInterfaceDetails(index: 1, up: up, running: up, loopback: false, pointToPoint: false,
            mtu: 1500, receivedBytes: 5_000_000_000, sentBytes: 1_250_000_000, receivedPackets: 900_000,
            sentPackets: 200_000, receivedErrors: 0, sentErrors: 0)
        let configuration = NetworkInterfaceConfiguration(addresses: .init(["192.0.2.10", "2001:db8::10"]),
            wifi: .init(powered: up, rssiDBm: up ? -55 : nil, noiseDBm: up ? -90 : nil,
                        channel: up ? 36 : nil, linkMegabitsPerSecond: up ? 866.7 : nil))
        let row = NetworkInterfaceMetrics(id: "en0", receivedBytesPerSecond: up && state == .available ? .init(2_500_000) : .init(state: state),
            sentBytesPerSecond: up && state == .available ? .init(500_000) : .init(state: state), details: details, configuration: configuration)
        let summary = NetworkMonitoringSummary(observedInterfaces: 1, configurationCapturedAt: date,
            primaryIPv4: "en0", primaryIPv6: "en0", routerIPv4: .init("192.0.2.1"), routerIPv6: .init("2001:db8::1"), dnsServers: .init(["192.0.2.53"]))
        let sample = MonitoringSample(group: .network, capturedAt: date, intervalSeconds: 1, state: state,
            payload: .network([row], summary: summary), stale: stale)
        let history: [MonitoringHistoryPoint] = (0..<60).map { index in
            let values: [String: Double] = ["en0.received": 2_500_000 + sin(Double(index) / 5) * 1_000_000,
                                            "en0.sent": 500_000 + sin(Double(index) / 5) * 100_000]
            return MonitoringHistoryPoint(capturedAt: date.addingTimeInterval(Double(index - 59)),
                state: index == 28 ? .warmingUp : state, values: index == 28 || !up || state != .available ? [:] : values)
        }
        let model = NetworkViewModel(provider: UnavailableLiveMonitoringService())
        model.accept(snapshot: MonitoringSnapshot(suspended: stopped, samples: [sample]), history: history)
        return model
    }

    private func render(_ model: NetworkViewModel, width: CGFloat, language: AgentLanguage,
                        theme: ColorScheme, suffix: String) async throws {
        let root = NetworkContent(model: model).environment(\.agentLanguage, language)
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
        if let path = ProcessInfo.processInfo.environment["ATHENA_NETWORK_SCREENSHOTS_DIR"] {
            let directory = URL(fileURLWithPath: path)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let file = directory.appendingPathComponent("network-\(language.rawValue)-\(theme == .light ? "light" : "dark")-\(Int(width))-\(suffix).png")
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: file)
        }
    }

    func testNetworkRendersBothThemesLanguagesAndCompactWideLayouts() async throws {
        for language in AgentLanguage.allCases {
            for theme in [ColorScheme.light, .dark] {
                for width: CGFloat in [520, 1000] {
                    try await render(model(), width: width, language: language, theme: theme, suffix: "total")
                }
            }
        }
    }
    func testUnavailableStaleAndEmergencyScreensRender() async throws {
        try await render(model(up: false), width: 520, language: .russian, theme: .dark, suffix: "offline")
        try await render(model(state: .warmingUp), width: 520, language: .english, theme: .light, suffix: "unavailable")
        try await render(model(stale: true), width: 520, language: .russian, theme: .light, suffix: "stale")
        try await render(model(stopped: true), width: 520, language: .english, theme: .dark, suffix: "stopped")
    }
    func testNewNavigationAndLocalizedLabelsHaveCompleteCatalogues() {
        for language in AgentLanguage.allCases {
            let l10n = AthenaLocalization(language: language)
            XCTAssertNotEqual(l10n.text(AppSection.network.title), AthenaLocalization.unavailable)
            XCTAssertNotEqual(l10n.text("График сетевого трафика"), AthenaLocalization.unavailable)
        }
        XCTAssertEqual(SidebarView.destination(from: .processor, direction: .down), .network)
        XCTAssertEqual(SidebarView.destination(from: .memory, direction: .down), .battery)
        XCTAssertEqual(SidebarView.destination(from: .network, direction: .down), .disk)
    }
}

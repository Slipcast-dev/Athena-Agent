import AppKit
import SwiftUI
import XCTest
import EcosystemLocalization
@testable import MacAssistantCore
@testable import MacAssistant

/// Только fixture-результат: данному источнику не передаются реальные пути.
private struct LanguageStorageFixture: StorageAnalyzing {
    func storageOverview() async throws -> StorageOverview { .init(totalBytes: 1000, availableBytes: 500) }
    func scanDirectory(at url: URL, minimumSizeBytes: UInt64) async throws -> [StorageItem] {
        [.init(url: url.appendingPathComponent("Мои данные %@ / Large example.bin"), sizeBytes: minimumSizeBytes + 1, modifiedAt: nil, isDirectory: false)]
    }
}

@MainActor final class AthenaScreensTests: XCTestCase {
    private func render<V: View>(_ view: V, name: String, language: AgentLanguage, theme: ColorScheme) async throws {
        let host = NSHostingView(rootView: view.environment(\.agentLanguage, language).environment(\.colorScheme, theme)
            .frame(width: 760, height: 900).background(Color(nsColor: .windowBackgroundColor)))
        host.frame = NSRect(x: 0, y: 0, width: 760, height: 900)
        let window = NSWindow(contentRect: host.bounds, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host
        window.appearance = NSAppearance(named: theme == .light ? .aqua : .darkAqua)
        defer { window.close() }
        // На macOS 15 AppKit-backed List не рисует строки в никогда не показанном
        // окне. Показываем только синтетическое test window без реального runtime;
        // одного layout недостаточно для подтверждения растеризации списка.
        window.orderFrontRegardless()
        window.displayIfNeeded()
        try await Task.sleep(for: .milliseconds(150))
        host.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        // Шаг 16 может систематически пропустить тонкие строки текста на плоской
        // теме macOS 15. Более плотная сетка сохраняет прежний порог, а не
        // превращает пустую рамку в успешную проверку.
        var colors = Set<Int>()
        for y in stride(from: 0, to: bitmap.pixelsHigh, by: 4) {
            for x in stride(from: 0, to: bitmap.pixelsWide, by: 4) {
                if let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) {
                    colors.insert(Int(color.redComponent * 255) << 16 | Int(color.greenComponent * 255) << 8 | Int(color.blueComponent * 255))
                }
            }
            if colors.count > 8 { break }
        }
        XCTAssertGreaterThan(colors.count, 8, "Empty offscreen frame: " + name)
        if let path = ProcessInfo.processInfo.environment["ECOSYSTEM_UI_SNAPSHOTS_DIR"] {
            let folder = URL(fileURLWithPath: path)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                .write(to: folder.appendingPathComponent("athena-\(name)-\(language.rawValue)-\(theme == .light ? "light" : "dark").png"))
        }
    }
    func testScreensInBothLanguagesAndThemes() async throws {
        let metrics = AthenaLocalizationTests.metrics()
        let system = LanguageSystemFixture(metrics: metrics)
        let info = try await system.systemInfo()
        let diagnostics = DiagnosticsViewModel(diagnostics: SystemDiagnosticsService(systemInformation: system))
        await diagnostics.run()
        let originalReport = diagnostics.report
        let storageService = LanguageStorageFixture()
        let storage = FolderAnalysisViewModel(storage: storageService)
        storage.startScan(directory: URL(fileURLWithPath: "/fixture/Обзор/LongFolder/LongFolder"))
        for _ in 0..<100 where storage.state == .loading { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(storage.items.count, 1)
        let monitor = MonitorViewModel(client: nil)
        let states: [MonitorStatus] = [.normal, .warmingUp, .warning, .critical, .recovered, .unavailable]
        monitor.entries = states.enumerated().map { index, state in
            var rule = MonitorRule(); rule.name = "Мой монитор %@ — " + String(index)
            var entry = MonitorEntry(rule: rule); entry.enabled = true; entry.state.status = state
            return entry
        }
        var rule = MonitorRule(); rule.metric = .memoryPressure; rule.name = "Моя проверка — user name"
        rule.warning = 1; rule.critical = 2; rule.recovery = 0
        let base = ServiceDependencies.unavailable
        let bridge = LocalAgentBridge(systemInformation: system, diagnostics: SystemDiagnosticsService(systemInformation: system), storage: storageService)
        let connections = AgentConnectionsViewModel(agentBridge: bridge, connections: base.mcpConnections)
        for language in AgentLanguage.allCases {
            for theme in [ColorScheme.light, .dark] {
                try await render(Form { Section("Mac") { SystemIdentityRows(info: info) } }.formStyle(.grouped), name: "mac-info", language: language, theme: theme)
                try await render(DiagnosticsView(viewModel: diagnostics), name: "diagnostics", language: language, theme: theme)
                try await render(FolderAnalysisView(viewModel: storage), name: "folder-analysis", language: language, theme: theme)
                try await render(MonitorPanel(model: monitor), name: "monitor", language: language, theme: theme)
                try await render(MonitorReviewContent(rule: rule, expiresAt: Date().addingTimeInterval(600), error: nil, l10n: AthenaLocalization(language: language)).padding(24).frame(width: 500), name: "approval", language: language, theme: theme)
                try await render(PreferencesView(connections: connections), name: "preferences", language: language, theme: theme)
                try await render(VStack {
                    FeatureScreen(title: "", state: .loading) { EmptyView() }
                    FeatureScreen(title: "", state: .error(message: "Original external error")) { EmptyView() }
                }, name: "states", language: language, theme: theme)
            }
        }
        XCTAssertEqual(diagnostics.report, originalReport)
        XCTAssertEqual(monitor.entries.map(\.state.status), states)
    }
}

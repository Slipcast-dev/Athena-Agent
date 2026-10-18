import XCTest
import SwiftUI
import AppKit
import MacAssistantCore
import EcosystemClientAdapters
@testable import MacAssistant

/// Двойник моделирует только конфигурацию, не запускает сторонние клиенты и
/// позволяет доказать отсутствие скрытых подключений при открытии формы.
private actor SettingsConnections: MCPConnectionManaging {
    var values: [MCPClient: MCPConnectionStatus]
    var changes: [String] = []
    let fails: Bool

    init(configured: Bool = false, fails: Bool = false) {
        values = [.codex: configured ? .configured : .notConfigured,
                  .deepSeekHarness: configured ? .configured : .notConfigured]
        self.fails = fails
    }

    func status(for client: MCPClient) async -> MCPConnectionStatus { values[client] ?? .notConfigured }
    func connect(_ client: MCPClient) async throws -> MCPConnectionStatus {
        changes.append("connect:\(client.rawValue)")
        if fails { throw ServiceError.unavailable(feature: "Тестовое подключение") }
        values[client] = .configured
        return .configured
    }
    func disconnect(_ client: MCPClient) async throws -> MCPConnectionStatus {
        changes.append("disconnect:\(client.rawValue)")
        if fails { throw ServiceError.unavailable(feature: "Тестовое отключение") }
        values[client] = .notConfigured
        return .notConfigured
    }
}

@MainActor
final class SettingsTests: XCTestCase {
    func testOnlyLocalSectionsRemain() {
        XCTAssertEqual(AppSection.allCases.map(\.rawValue), ["dashboard", "diagnostics", "storage", "settings"])
        XCTAssertEqual(AppSection.allCases.map(\.title), ["Обзор", "Диагностика", "Накопитель", "Настройки"])
    }

    func testRemovedSelectionsHaveSafeDestinations() {
        XCTAssertEqual(AppSection.restored(from: "agents"), .settings)
        for previous in ["aiChat", "providers", "unknown"] {
            XCTAssertEqual(AppSection.restored(from: previous), .dashboard)
        }
        XCTAssertEqual(AppSection.restored(from: "storage"), .storage)
    }

    func testSettingsHaveClearBlocks() {
        XCTAssertEqual(SettingsBlock.allCases.map(\.rawValue),
                       ["Оформление", "Подключения", "Доступ и безопасность", "О приложении"])
    }

    func testOpeningSettingsOnlyReadsAndLoadsCommands() async {
        let service = SettingsConnections(configured: true)
        let vm = AgentConnectionsViewModel(agentBridge: AppContainer.makeDefault().services.agentBridge, connections: service)
        await vm.load()
        XCTAssertEqual(vm.status(for: .codex), .configured)
        XCTAssertEqual(vm.status(for: .deepSeekHarness), .configured)
        XCTAssertEqual(vm.commands.map(\.id), ["system.get_info", "system.get_metrics", "diagnostics.run", "storage.get_overview"])
        let changes = await service.changes
        XCTAssertTrue(changes.isEmpty)
    }

    func testBothClientsCanConnectAndDisconnectIndependently() async {
        let service = SettingsConnections()
        let vm = AgentConnectionsViewModel(agentBridge: AppContainer.makeDefault().services.agentBridge, connections: service)
        await vm.load()
        for client in MCPClient.allCases { await vm.connect(client) }
        await vm.disconnect(.codex)
        XCTAssertEqual(vm.status(for: .codex), .notConfigured)
        XCTAssertEqual(vm.status(for: .deepSeekHarness), .configured)
        await vm.disconnect(.deepSeekHarness)
        XCTAssertEqual(vm.status(for: .deepSeekHarness), .notConfigured)
        XCTAssertFalse(vm.isUpdatingConnection)
        XCTAssertNil(vm.error)
    }

    func testFailedDisconnectKeepsConfiguredStatus() async {
        let service = SettingsConnections(configured: true, fails: true)
        let vm = AgentConnectionsViewModel(agentBridge: AppContainer.makeDefault().services.agentBridge, connections: service)
        await vm.disconnect(.codex)
        XCTAssertEqual(vm.status(for: .codex), .configured)
        XCTAssertNotNil(vm.error)
        XCTAssertFalse(vm.isUpdatingConnection)
    }

    func testSettingsRenderInBothThemesAndWindowSizes() async throws {
        let output = ProcessInfo.processInfo.environment["MACASSISTANT_UI_SNAPSHOTS_DIR"]
        for configured in [false, true] {
            let service = SettingsConnections(configured: configured)
            let vm = AgentConnectionsViewModel(agentBridge: AppContainer.makeDefault().services.agentBridge, connections: service)
            await vm.load()
            for theme in [ColorScheme.light, .dark] {
                for width: CGFloat in [500, 900] {
                    let root = PreferencesView(connections: vm).environment(\.colorScheme, theme)
                        .frame(width: width, height: 650)
                    let host = NSHostingView(rootView: root)
                    host.frame = NSRect(x: 0, y: 0, width: width, height: 650)
                    host.layoutSubtreeIfNeeded()
                    let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                    host.cacheDisplay(in: host.bounds, to: bitmap)
                    XCTAssertGreaterThanOrEqual(bitmap.pixelsWide, Int(width))
                    if let output {
                        let directory = URL(fileURLWithPath: output, isDirectory: true)
                        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                        let name = "settings-\(configured)-\(theme == .light ? "light" : "dark")-\(Int(width)).png"
                        try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                            .write(to: directory.appendingPathComponent(name))
                    }
                }
            }
        }
    }
}

/// Подтверждение SwiftUI закрывает диалог раньше асинхронного обработчика.
/// Переданный снимок плана должен переживать очистку presentation state.
private actor CodexPreviewConnections: MCPConnectionManaging {
    private var configured = false
    private(set) var applied: [String] = []
    func status(for client: MCPClient) -> MCPConnectionStatus { configured ? .configured : .notConfigured }
    func connect(_ client: MCPClient) throws -> MCPConnectionStatus { throw ServiceError.invalidInput(reason: "Ожидался подтверждённый план") }
    func disconnect(_ client: MCPClient) throws -> MCPConnectionStatus { throw ServiceError.invalidInput(reason: "Ожидался подтверждённый план") }
    func previewCodexConnection(connected: Bool) throws -> CodexConnectionPlan {
        let object: [String: Any] = ["domain": "athena", "connected": connected, "fingerprint": "shown-plan",
            "changes": ["Добавить роль Athena"], "warnings": []]
        return try JSONDecoder().decode(CodexConnectionPlan.self, from: JSONSerialization.data(withJSONObject: object))
    }
    func applyCodexConnection(_ plan: CodexConnectionPlan) -> MCPConnectionStatus {
        applied.append(plan.fingerprint); configured = plan.connected
        return configured ? .configured : .notConfigured
    }
}

extension SettingsTests {
    func testConfirmedCodexPlanSurvivesDialogDismissal() async throws {
        let service = CodexPreviewConnections()
        let model = AgentConnectionsViewModel(agentBridge: AppContainer.makeDefault().services.agentBridge, connections: service)
        await model.prepareCodexConnection(connected: true)
        let shownPlan = try XCTUnwrap(model.codexPlan)
        let before = await service.applied
        XCTAssertTrue(before.isEmpty, "Просмотр не регистрирует соединение")
        model.codexPlan = nil
        await model.applyCodexPlan(shownPlan)
        XCTAssertEqual(model.status(for: .codex), .configured)
        let applied = await service.applied
        XCTAssertEqual(applied, ["shown-plan"])
        XCTAssertNil(model.codexPlan)
        XCTAssertNil(model.error)
    }
}

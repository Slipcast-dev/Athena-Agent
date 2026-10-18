import XCTest
import EcosystemClientAdapters
@testable import MacAssistantCore

final class MCPConnectionServiceTests: XCTestCase {
    /// Настоящий CLI проверяет схему в отдельном CODEX_HOME. Модель,
    /// авторизация и конфигурация рабочего пользователя в тесте не затрагиваются.
    func testCodexConnectionUsesOwnedRoleAndActualFiles() async throws {
        guard let cli = MCPConnectionService.defaultCodexExecutableURL() else {
            throw XCTSkip("Codex CLI не установлен")
        }
        let home = URL(fileURLWithPath: "/private/tmp", isDirectory: true).appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        let codexHome = home.appendingPathComponent(".codex")
        try FileManager.default.createDirectory(at: codexHome, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        let config = codexHome.appendingPathComponent("config.toml")
        let foreign = "model = \"test-model\"\n[mcp_servers.foreign]\ncommand = \"/usr/bin/false\"\n"
        try Data(foreign.utf8).write(to: config)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: config.path)
        let service = MCPConnectionService(homeDirectory: home,
            executableLocator: { URL(fileURLWithPath: "/usr/bin/true") },
            codexHomeDirectory: codexHome, codexExecutableURL: cli)
        let initial = await service.status(for: .codex)
        XCTAssertEqual(initial, .notConfigured)
        let plan = try await service.previewCodexConnection(connected: true)
        XCTAssertFalse(plan.changes.isEmpty)
        XCTAssertEqual(try String(contentsOf: config), foreign, "Просмотр не записывает профиль")
        let active = try await service.applyCodexConnection(plan)
        XCTAssertEqual(active, .configured)
        let registered = try String(contentsOf: config)
        XCTAssertTrue(try String(contentsOf: codexHome.appendingPathComponent("agents/athena.toml")).contains("name = \"athena\""))
        XCTAssertTrue(registered.contains("[mcp_servers.athena]"))
        XCTAssertTrue(registered.contains("[mcp_servers.foreign]"))
        // Новый сервис читает реальный профиль: локального флага недостаточно.
        let reloaded = MCPConnectionService(homeDirectory: home,
            executableLocator: { URL(fileURLWithPath: "/usr/bin/true") },
            codexHomeDirectory: codexHome, codexExecutableURL: cli)
        let persisted = await reloaded.status(for: .codex)
        XCTAssertEqual(persisted, .configured)
        let inactive = try await reloaded.disconnect(.codex)
        XCTAssertEqual(inactive, .notConfigured)
        XCTAssertEqual(try String(contentsOf: config), foreign)
    }

    func testCodexRejectsForeignEntryAndStalePreviewWithoutWriting() async throws {
        guard let cli = MCPConnectionService.defaultCodexExecutableURL() else {
            throw XCTSkip("Codex CLI не установлен")
        }
        let home = URL(fileURLWithPath: "/private/tmp", isDirectory: true).appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        let codexHome = home.appendingPathComponent(".codex")
        try FileManager.default.createDirectory(at: codexHome, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        let config = codexHome.appendingPathComponent("config.toml")
        try Data("model = \"first\"\n".utf8).write(to: config)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: config.path)
        let service = MCPConnectionService(homeDirectory: home,
            executableLocator: { URL(fileURLWithPath: "/usr/bin/true") },
            codexHomeDirectory: codexHome, codexExecutableURL: cli)
        let plan = try await service.previewCodexConnection(connected: true)
        let changed = "model = \"second\"\n"
        try Data(changed.utf8).write(to: config)
        do {
            _ = try await service.applyCodexConnection(plan)
            XCTFail("Изменённый профиль требует нового подтверждения")
        } catch let error as CodexAdapterError {
            guard case .stalePlan = error else { return XCTFail("Ожидался stalePlan") }
        }
        XCTAssertEqual(try String(contentsOf: config), changed)
        let foreign = "[mcp_servers.athena]\ncommand = \"/usr/bin/false\"\n"
        try Data(foreign.utf8).write(to: config)
        let status = await service.status(for: .codex)
        guard case .unavailable = status else { return XCTFail("Чужой сервер не считается нашим подключением") }
        do { _ = try await service.disconnect(.codex); XCTFail("Чужой сервер нельзя удалять") } catch { }
        XCTAssertEqual(try String(contentsOf: config), foreign)
    }

    /// Сторонние комментарии, выражения и прежняя запись MCP не принадлежат
    /// новому адаптеру. Подключение двух ролей не разрешает их нормализацию.
    func testHarnessRoundtripPreservesForeignCommentsAndLegacyServer() async throws {
        let home = try harnessHome(); defer { try? FileManager.default.removeItem(at: home) }
        let file = HarnessInstallation.patchURL(homeDirectory: home.appendingPathComponent(".dsh"))
        let original = "# Оставить комментарий\n- insert:\n    - id: mcp-mac-assistant\n      name: foreign-client\n      config:\n        literal: !!js process.env.DO_NOT_EVALUATE\n"
        try original.write(to: file, atomically: true, encoding: .utf8)
        let service = harnessService(home)
        let preview = try await service.previewHarnessConnection(connected: true)
        XCTAssertEqual(try String(contentsOf: file), original)
        let active = try await service.applyHarnessConnection(preview)
        XCTAssertEqual(active, .configured)
        XCTAssertTrue(try String(contentsOf: file).contains("delegate_athena"))
        _ = try await service.connect(.deepSeekHarness)
        _ = try await service.disconnect(.deepSeekHarness)
        XCTAssertEqual(try String(contentsOf: file), original)
        let inactive = await service.status(for: .deepSeekHarness)
        XCTAssertEqual(inactive, .notConfigured)
    }

    func testHarnessRejectsForeignRoleAndNeverDeletesIt() async throws {
        let home = try harnessHome(); defer { try? FileManager.default.removeItem(at: home) }
        let file = HarnessInstallation.patchURL(homeDirectory: home.appendingPathComponent(".dsh"))
        let original = "- insert:\n    - id: ecosystem-athena-delegate\n      name: foreign-client\n"
        try original.write(to: file, atomically: true, encoding: .utf8)
        let service = harnessService(home)
        do { _ = try await service.connect(.deepSeekHarness); XCTFail("Чужая роль принята") } catch { }
        do { _ = try await service.disconnect(.deepSeekHarness); XCTFail("Чужая роль удалена") } catch { }
        XCTAssertEqual(try String(contentsOf: file), original)
        let status = await service.status(for: .deepSeekHarness)
        guard case .unavailable = status else { return XCTFail("Чужая роль не настроенное подключение") }
    }

    func testHarnessMalformedYamlAndStalePlanDoNotOverwriteFile() async throws {
        let home = try harnessHome(); defer { try? FileManager.default.removeItem(at: home) }
        let file = HarnessInstallation.patchURL(homeDirectory: home.appendingPathComponent(".dsh"))
        let service = harnessService(home)
        for yaml in ["- insert: [broken", "- insert: []\n---\n- insert: []", "- insert: wrong", "- insert:\n  - id: neighbor\n    id: duplicate"] {
            try yaml.write(to: file, atomically: true, encoding: .utf8)
            do { _ = try await service.previewHarnessConnection(connected: true); XCTFail("Некорректный YAML принят") } catch { }
            XCTAssertEqual(try String(contentsOf: file), yaml)
        }
        try "[]\n".write(to: file, atomically: true, encoding: .utf8)
        let plan = try await service.previewHarnessConnection(connected: true)
        let changed = "# Сохранено редактором\n[]\n"
        try changed.write(to: file, atomically: true, encoding: .utf8)
        do { _ = try await service.applyHarnessConnection(plan); XCTFail("Устаревший план применён") } catch { }
        XCTAssertEqual(try String(contentsOf: file), changed)
    }

    func testHarnessExplicitHomeUsesDesktopProfileAndPreservesRootPatch() async throws {
        let home = try harnessHome(); defer { try? FileManager.default.removeItem(at: home) }
        let alternate = home.appendingPathComponent("alternate")
        let file = HarnessInstallation.patchURL(homeDirectory: alternate)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try "[]\n".write(to: file, atomically: true, encoding: .utf8)
        let rootPatch = home.appendingPathComponent(".dsh/cordis.patch.yml")
        try "# legacy root patch\n[]\n".write(to: rootPatch, atomically: true, encoding: .utf8)
        let service = MCPConnectionService(homeDirectory: home,
            executableLocator: { URL(fileURLWithPath: "/usr/bin/true") },
            harnessHomeDirectory: alternate, harnessInstalledVersion: "0.2.0-rc.2")
        _ = try await service.connect(.deepSeekHarness)
        XCTAssertTrue(try String(contentsOf: file).contains("delegate_athena"))
        XCTAssertEqual(try String(contentsOf: rootPatch), "# legacy root patch\n[]\n")
        _ = try await service.disconnect(.deepSeekHarness)
    }

    private func harnessHome() throws -> URL {
        let home = URL(fileURLWithPath: "/private/tmp").appendingPathComponent("ecosystem-e10-native-" + UUID().uuidString)
        let profile = home.appendingPathComponent(".dsh/profiles/desktop")
        try FileManager.default.createDirectory(at: profile, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return home
    }

    private func harnessService(_ home: URL) -> MCPConnectionService {
        MCPConnectionService(homeDirectory: home,
            executableLocator: { URL(fileURLWithPath: "/usr/bin/true") },
            harnessInstalledVersion: "0.2.0-rc.2")
    }
}

import Foundation
import EcosystemLocalIPC
import EcosystemClientAdapters

/// Настраивает только собственный локальный MCP-исполнитель Athena.
/// Сервис не принимает команду, путь или YAML от агента: все значения определены
/// приложением, а запись Harness ограничена стабильным `id`.
public actor MCPConnectionService: MCPConnectionManaging {
    private let fileManager: FileManager
    private let homeDirectory: URL
    private let executableLocator: @Sendable () -> URL?
    private let codexHomeDirectory: URL
    private let codexExecutableURL: URL?
    private let harnessHomeDirectory: URL
    private let harnessInstalledVersion: String

    public init(
        fileManager: FileManager = .default,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        executableLocator: @escaping @Sendable () -> URL? = { MCPConnectionService.defaultExecutableURL() },
        codexHomeDirectory: URL? = nil,
        codexExecutableURL: URL? = MCPConnectionService.defaultCodexExecutableURL(),
        harnessHomeDirectory: URL? = nil,
        harnessInstalledVersion: String? = HarnessInstallation.detectedVersion()
    ) {
        self.fileManager = fileManager
        self.homeDirectory = homeDirectory
        self.executableLocator = executableLocator
        self.codexExecutableURL = codexExecutableURL
        self.harnessHomeDirectory = HarnessInstallation.homeDirectory(homeDirectory: homeDirectory, override: harnessHomeDirectory)
        self.harnessInstalledVersion = harnessInstalledVersion ?? "unavailable"
        // Явный тестовый home всегда изолирован от настоящего CODEX_HOME.
        // В приложении учитываем выбранный пользователем профиль Codex.
        if let codexHomeDirectory {
            self.codexHomeDirectory = codexHomeDirectory
        } else if homeDirectory.standardizedFileURL == FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL,
                  let path = ProcessInfo.processInfo.environment["CODEX_HOME"], path.hasPrefix("/") {
            self.codexHomeDirectory = URL(fileURLWithPath: path, isDirectory: true)
        } else {
            self.codexHomeDirectory = homeDirectory.appendingPathComponent(".codex", isDirectory: true)
        }
    }

    public func status(for client: MCPClient) async -> MCPConnectionStatus {
        switch client {
        case .codex:
            do {
                return Self.connectionStatus(try await codexAdapter().status())
            } catch {
                return .unavailable(reason: error.localizedDescription)
            }
        case .deepSeekHarness:
            do { return Self.harnessStatus(try await harnessAdapter().status()) }
            catch { return .unavailable(reason: error.localizedDescription) }
        }
    }

    public func connect(_ client: MCPClient) async throws -> MCPConnectionStatus {
        guard let located = executableLocator() else { return .unavailable(reason: "MCP-исполнитель приложения не найден.") }
        let executable: URL
        if located.lastPathComponent == "athena-mcp.command" {
            executable = located.deletingLastPathComponent().appendingPathComponent("athena-" + (client == .codex ? "codex" : "deepseekHarness") + "-mcp.command")
        } else { executable = located }
        guard fileManager.isExecutableFile(atPath: executable.path) else {
            return .unavailable(reason: "MCP-исполнитель приложения не найден. Переустановите Athena.")
        }

        switch client {
        case .codex:
            let plan = try await previewCodexConnection(connected: true)
            return try await applyCodexConnection(plan)
        case .deepSeekHarness:
            let plan = try await previewHarnessConnection(connected: true)
            return try await applyHarnessConnection(plan)
        }
    }

    public func disconnect(_ client: MCPClient) async throws -> MCPConnectionStatus {
        switch client {
        case .codex:
            let plan = try await previewCodexConnection(connected: false)
            return try await applyCodexConnection(plan)
        case .deepSeekHarness:
            let plan = try await previewHarnessConnection(connected: false)
            return try await applyHarnessConnection(plan)
        }
    }

    /// Один адаптер обеспечивает одинаковое владение, резервные копии и
    /// сохранение чужих YAML-байтов в обоих независимых приложениях.
    public func previewHarnessConnection(connected: Bool) async throws -> HarnessConnectionPlan {
        try await harnessAdapter().preview(connected: connected)
    }

    @discardableResult
    public func applyHarnessConnection(_ plan: HarnessConnectionPlan) async throws -> MCPConnectionStatus {
        Self.harnessStatus(try await harnessAdapter().apply(plan))
    }

    private func harnessAdapter() throws -> HarnessAdapter {
        guard let located = executableLocator() else {
            throw ServiceError.unavailableFeature(.athenaMCPExecutable)
        }
        let helper = located.lastPathComponent == "athena-mcp.command"
            ? located.deletingLastPathComponent().appendingPathComponent("athena-deepseekHarness-mcp.command") : located
        return HarnessAdapter(configuration: HarnessAdapterConfiguration(domain: .athena,
            patchURL: HarnessInstallation.patchURL(homeDirectory: harnessHomeDirectory),
            helperURL: helper, installedVersion: harnessInstalledVersion, profile: "desktop"))
    }

    private static func harnessStatus(_ value: HarnessAdapterStatus) -> MCPConnectionStatus {
        if value.connected { return .configured }
        return value.state == "disconnected" ? .notConfigured : .unavailable(reason: value.detail)
    }

    /// Предварительный просмотр не запускает модель и не меняет записи подключения Codex.
    public func previewCodexConnection(connected: Bool) async throws -> CodexConnectionPlan {
        try await codexAdapter().preview(connected: connected)
    }

    /// Запись разрешена только при совпадении отпечатка просмотренного плана.
    @discardableResult
    public func applyCodexConnection(_ plan: CodexConnectionPlan) async throws -> MCPConnectionStatus {
        Self.connectionStatus(try await codexAdapter().apply(plan))
    }

    private func codexAdapter() throws -> CodexAdapter {
        guard let located = executableLocator() else {
            throw MCPConnectionError.codexRegistrationFailed(message: "MCP-исполнитель приложения не найден.")
        }
        let executable = located.lastPathComponent == "athena-mcp.command"
            ? located.deletingLastPathComponent().appendingPathComponent("athena-codex-mcp.command")
            : located
        return CodexAdapter(configuration: CodexAdapterConfiguration(
            domain: .athena, configDirectory: codexHomeDirectory,
            helperURL: executable, codexExecutableURL: codexExecutableURL
        ))
    }

    private static func connectionStatus(_ status: CodexAdapterStatus) -> MCPConnectionStatus {
        switch status.state {
        case "connected": return .configured
        case "disconnected": return .notConfigured
        default: return .unavailable(reason: status.detail)
        }
    }

    /// Используем только известный исполняемый файл установленного приложения:
    /// shell и изменяемый PATH не участвуют в регистрации пользовательского профиля.
    public static func defaultCodexExecutableURL() -> URL? {
        let candidates = [
            "/Applications/Codex.app/Contents/Resources/codex",
            "/Applications/Codex.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex",
            "/Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex"
        ]
        return candidates.map { URL(fileURLWithPath: $0) }
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    /// Публичность нужна только потому, что метод участвует в значении по
    /// умолчанию публичного инициализатора; это не делает его MCP-командой.
    public static func defaultExecutableURL() -> URL? {
        if ProcessInfo.processInfo.environment["ATHENA_LOCAL_RUNTIME_CONFIG"] != nil {
            guard let (_, file) = try? LocalRuntimeConfiguration.environment(domain: "athena") else { return nil }
            return file.deletingLastPathComponent().appendingPathComponent("athena-mcp.command")
        }
        let bundleURL = Bundle.main.bundleURL
        let bundled = bundleURL.appendingPathComponent("Contents/MacOS/MacAssistantMCP")
        if FileManager.default.isExecutableFile(atPath: bundled.path) { return bundled }
        // SwiftPM-разработка хранит оба исполняемых файла в одном каталоге.
        return Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent("MacAssistantMCP")
    }
}

public enum MCPConnectionError: LocalizedError, Sendable {
    case codexRegistrationFailed(message: String)

    public var errorDescription: String? {
        switch self {
        case let .codexRegistrationFailed(message):
            return message.isEmpty ? "Codex не смог зарегистрировать MCP-исполнитель." : "Codex не смог зарегистрировать MCP-исполнитель: \(message)"
        }
    }
}

import Darwin
import Foundation
import EcosystemClientAdapters

/// Явный локальный инструмент: preview никогда не регистрирует соединение.
/// Apply принимает сохранённый план, который адаптер повторно связывает с файлами.
@main
struct CodexAgentTool {
    static func main() async {
        umask(0o077)
        do {
            let arguments = Array(CommandLine.arguments.dropFirst())
            if arguments == ["--help"] {
                print("CodexAgentTool --action preview-connect|preview-disconnect|apply|recover|status --domain ares|athena --config-directory PATH --helper PATH [--codex PATH] [--plan-file PATH]")
                return
            }
            var values: [String: String] = [:]
            guard arguments.count.isMultiple(of: 2) else { throw CodexAdapterError.invalidConfiguration }
            for index in stride(from: 0, to: arguments.count, by: 2) {
                let key = arguments[index]
                guard ["--action", "--domain", "--config-directory", "--helper", "--codex", "--plan-file"].contains(key), values[key] == nil else { throw CodexAdapterError.invalidConfiguration }
                values[key] = arguments[index + 1]
            }
            guard let action = values["--action"], let domain = values["--domain"].flatMap(CodexAgentDomain.init(rawValue:)),
                  let directory = values["--config-directory"], directory.hasPrefix("/"),
                  let helper = values["--helper"], helper.hasPrefix("/") else { throw CodexAdapterError.invalidConfiguration }
            let executable = values["--codex"].map { URL(fileURLWithPath: $0) } ?? locateCodex()
            let adapter = CodexAdapter(configuration: CodexAdapterConfiguration(domain: domain,
                configDirectory: URL(fileURLWithPath: directory), helperURL: URL(fileURLWithPath: helper), codexExecutableURL: executable))
            switch action {
            case "preview-connect", "preview-disconnect":
                let plan = try await adapter.preview(connected: action == "preview-connect")
                let data = try encode(plan)
                if let path = values["--plan-file"] {
                    let file = URL(fileURLWithPath: path)
                    try data.write(to: file, options: .withoutOverwriting)
                    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
                }
                FileHandle.standardOutput.write(data + Data([10]))
            case "apply":
                guard let path = values["--plan-file"] else { throw CodexAdapterError.invalidConfiguration }
                var info = stat()
                guard lstat(path, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == geteuid(),
                      info.st_nlink == 1, info.st_mode & 0o077 == 0, (1...65_536).contains(info.st_size) else { throw CodexAdapterError.unsafePath }
                let plan = try JSONDecoder().decode(CodexConnectionPlan.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
                let status = try await adapter.apply(plan)
                FileHandle.standardOutput.write(try encode(status) + Data([10]))
            case "recover": FileHandle.standardOutput.write(try encode(await adapter.recoverConnection()) + Data([10]))
            case "status": FileHandle.standardOutput.write(try encode(await adapter.status()) + Data([10]))
            default: throw CodexAdapterError.invalidConfiguration
            }
        } catch let error as CodexAdapterError {
            fputs((error.errorDescription ?? "Ошибка подключения Codex.") + "\n", stderr); exit(64)
        } catch {
            // Не экспортируем ошибки декодирования либо чужое содержимое файлов.
            fputs("Не удалось выполнить локальную операцию подключения Codex.\n", stderr); exit(65)
        }
    }
    private static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }
    private static func locateCodex() -> URL? {
        let candidates = ["/Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex",
                          "/Applications/Codex.app/Contents/Resources/codex", "/opt/homebrew/bin/codex", "/usr/local/bin/codex"]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }.map { URL(fileURLWithPath: $0) }
    }
}

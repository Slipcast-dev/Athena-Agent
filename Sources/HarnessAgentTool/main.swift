import Darwin
import Foundation
import EcosystemLocalization
import EcosystemClientAdapters

/// Локальная регистрация поддерживаемого desktop-профиля. CLI не загружает
/// исполняемые YAML-выражения и не создаёт сеанс модели Harness.
@main
struct HarnessAgentTool {
    static func main() async {
        if LocalizationProbe.runIfRequested() { return }
        umask(0o077)
        do {
            let arguments = Array(CommandLine.arguments.dropFirst())
            if arguments == ["--help"] {
                print(AgentLocalization(language: RuntimeLocalization.clientLanguage).runtimeText("cli.connectionHelp"))
                print("HarnessAgentTool --action preview-connect|preview-disconnect|apply|recover|status --domain ares|athena --patch PATH --helper PATH [--application PATH] [--profile desktop] [--plan-file PATH]")
                return
            }
            var values: [String: String] = [:]
            guard arguments.count.isMultiple(of: 2) else { throw HarnessAdapterError.invalidConfiguration }
            for index in stride(from: 0, to: arguments.count, by: 2) {
                let key = arguments[index]
                guard ["--action", "--domain", "--patch", "--helper", "--application", "--profile", "--plan-file"].contains(key), values[key] == nil else {
                    throw HarnessAdapterError.invalidConfiguration
                }
                values[key] = arguments[index + 1]
            }
            guard let action = values["--action"],
                  let domain = values["--domain"].flatMap(HarnessAgentDomain.init(rawValue:)),
                  let patch = values["--patch"], patch.hasPrefix("/"),
                  let helper = values["--helper"], helper.hasPrefix("/") else { throw HarnessAdapterError.invalidConfiguration }
            let profile = values["--profile"] ?? "desktop"
            guard profile.range(of: #"^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$"#, options: .regularExpression) != nil else {
                throw HarnessAdapterError.invalidConfiguration
            }
            let application = values["--application"].map { URL(fileURLWithPath: $0) }
            let version = HarnessInstallation.detectedVersion(applicationURL: application) ?? "unavailable"
            let adapter = HarnessAdapter(configuration: HarnessAdapterConfiguration(domain: domain,
                patchURL: URL(fileURLWithPath: patch), helperURL: URL(fileURLWithPath: helper),
                installedVersion: version, profile: profile))
            switch action {
            case "preview-connect", "preview-disconnect":
                let plan = try await adapter.preview(connected: action == "preview-connect")
                let data = try encode(plan)
                if let path = values["--plan-file"] {
                    guard path.hasPrefix("/") else { throw HarnessAdapterError.unsafePath }
                    try data.write(to: URL(fileURLWithPath: path), options: .withoutOverwriting)
                    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
                }
                FileHandle.standardOutput.write(data + Data([10]))
            case "apply":
                guard let path = values["--plan-file"], path.hasPrefix("/") else { throw HarnessAdapterError.invalidConfiguration }
                var info = stat()
                guard lstat(path, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
                      info.st_uid == geteuid(), info.st_nlink == 1, info.st_mode & 0o077 == 0,
                      (1...65_536).contains(info.st_size) else { throw HarnessAdapterError.unsafePath }
                let plan = try JSONDecoder().decode(HarnessConnectionPlan.self,
                    from: Data(contentsOf: URL(fileURLWithPath: path)))
                FileHandle.standardOutput.write(try encode(await adapter.apply(plan)) + Data([10]))
            case "recover":
                FileHandle.standardOutput.write(try encode(await adapter.recoverConnection()) + Data([10]))
            case "status":
                FileHandle.standardOutput.write(try encode(await adapter.status()) + Data([10]))
            default: throw HarnessAdapterError.invalidConfiguration
            }
        } catch let error as HarnessAdapterError {
            fputs(AgentLocalization(language: RuntimeLocalization.clientLanguage).runtimeError(error) + "\n", stderr)
            exit(64)
        } catch {
            // Исходная ошибка YAML/декодирования может содержать пользовательский
            // текст. CLI выдаёт только известное сообщение без его содержимого.
            fputs(AgentLocalization(language: RuntimeLocalization.clientLanguage).runtimeText("Не удалось выполнить локальную операцию подключения Harness.") + "\n", stderr)
            exit(65)
        }
    }

    private static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }
}

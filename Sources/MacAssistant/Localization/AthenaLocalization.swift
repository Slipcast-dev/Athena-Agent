import Foundation
import EcosystemLocalization

/// Сообщение хранит шаблон отдельно от внешних данных, чтобы смена языка могла
/// обновить уже полученный статус, но не переписать имя файла или историю службы.
indirect enum AthenaMessage: Equatable {
    case runtime(RuntimeMessage)
    case verbatim(String)
    case template(String, [AthenaMessage])

    init(_ key: String, args: [String] = []) {
        self = .template(key, args.map(Self.verbatim))
    }
    init(_ key: String, messages: [AthenaMessage]) {
        self = .template(key, messages)
    }
}

/// Явный язык resource bundle не зависит от языка процесса или глобального Locale.
/// Ключи — встроенный русский исходник; внешние строки допускаются только verbatim.
struct AthenaLocalization {
    let language: AgentLanguage
    static let unavailable = "Localization resource unavailable."
    private var table: Bundle? {
        Bundle.module.url(forResource: language.rawValue, withExtension: "lproj")
            .flatMap(Bundle.init(url:))
    }
    func text(_ key: String) -> String { render(AthenaMessage(key)) }
    func format(_ key: String, _ arguments: String...) -> String {
        render(AthenaMessage(key, args: arguments))
    }
    func format(_ key: String, args: String...) -> String {
        render(AthenaMessage(key, args: args))
    }
    func render(_ message: AthenaMessage) -> String {
        switch message {
        case .runtime(let value): return AgentLocalization(language: language).runtimeMessage(value)
        case .verbatim(let value): return value
        case .template(let key, let arguments):
            guard let table else { return Self.unavailable }
            let value = table.localizedString(forKey: key, value: Self.unavailable, table: "Athena")
            guard value != Self.unavailable else { return value }
            // Подстановка только %@ не выполняет printf и не интерпретирует
            // вставленные проценты/ключи повторно. Проверяем арность до рендера.
            let parts = value.components(separatedBy: "%@")
            guard parts.count == arguments.count + 1 else { return Self.unavailable }
            var output = parts[0]
            for (index, argument) in arguments.enumerated() {
                output += render(argument) + parts[index + 1]
            }
            return output
        }
    }

    /// Безопасная ранняя проверка ресурсов выполняется до bootstrap: не открывает
    /// профиль, не получает bookmarks и не запускает фоновые операции приложения.
    static func runProbeIfRequested() -> Bool {
        guard CommandLine.arguments.contains("--athena-localization-probe") else { return false }
        var samples: [[String: Any]] = []
        for language in AgentLanguage.allCases {
            let l10n = AthenaLocalization(language: language)
            let url = l10n.table?.url(forResource: "Athena", withExtension: "strings")
            let data = url.flatMap { try? Data(contentsOf: $0) }
            let dictionary = data.flatMap { try? PropertyListSerialization.propertyList(from: $0, format: nil) } as? [String: String] ?? [:]
            let main = Bundle.main.resourceURL?.standardizedFileURL.path ?? ""
            let placement = Bundle.main.bundleURL.pathExtension == "app"
                && (l10n.table?.bundleURL.standardizedFileURL.path.hasPrefix(main + "/") ?? false)
            samples.append(["language": language.rawValue, "count": dictionary.count,
                "complete": !dictionary.isEmpty && dictionary.values.allSatisfy { !$0.isEmpty },
                "placement": placement ? "application" : "swiftpm", "overview": l10n.text("Обзор")])
        }
        let data = try? JSONSerialization.data(withJSONObject: ["samples": samples], options: [.sortedKeys])
        if let data, let output = String(data: data, encoding: .utf8) { print(output) }
        return true
    }
}

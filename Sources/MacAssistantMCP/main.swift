import Foundation
import EcosystemLocalization
import MacAssistantCore
import EcosystemLocalIPC

/// Приложение и runtime остаются отдельными процессами. MCP main владеет только
/// stdio-сеансом, а общий transport не удерживает обработку во время ожидания.
@main
struct MacAssistantMCP {
    /// Описания fallback выбираются по ID, а не по тексту внешней команды.
    /// Имена инструментов и схемы остаются одинаковыми в обоих языках.
    private static func legacyDescription(_ id: String) -> String {
        switch id {
        case "system.get_info": return RuntimeLocalization.bilingual("Модель, версия macOS, архитектура и число ядер без серийного номера.")
        case "system.get_metrics": return RuntimeLocalization.bilingual("Текущие CPU, память и свободное место без истории процессов.")
        case "diagnostics.run": return RuntimeLocalization.bilingual("Структурированный отчёт и безопасные рекомендации, созданные локально.")
        case "storage.get_overview": return RuntimeLocalization.bilingual("Общий и доступный объём системного накопителя без путей и списка файлов.")
        default: return RuntimeLocalization.bilingual("Локальная операция Athena.")
        }
    }

    static func main() {
        if LocalizationProbe.runIfRequested() { return }
        if Array(CommandLine.arguments.dropFirst()) == ["--mcp-localization-probe"] {
            let value = ["local": AthenaMCP.tools + LocalCommonMCP.tools, "legacy": LocalAgentBridge.commands.map { ["name": $0.id, "description": legacyDescription($0.id), "inputSchema": ["type": "object", "properties": [:], "additionalProperties": false]] as [String: Any] }]
            if let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) {
                print(String(decoding: data, as: UTF8.self))
            }
            return
        }
        let dependencies = ServiceDependencies.makeLive(role: .mcp)
        let remote = dependencies.localRuntimeClient
        let tools: [[String: Any]] = remote != nil ? AthenaMCP.tools + LocalCommonMCP.tools : LocalAgentBridge.commands.map {
            ["name": $0.id, "description": legacyDescription($0.id),
             "inputSchema": ["type": "object", "properties": [:], "additionalProperties": false]]
        }
        let names = tools.compactMap { $0["name"] as? String }
        MCPStdioTransport.run(serverName: "mac-assistant", serverVersion: "0.38.1", tools: tools,
            experimental: ["ecosystemContracts": AthenaEcosystem.experimentalCapability]) { name, data, context in
            do {
                guard let args = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw LocalRuntimeFailure.invalidRequest }
                if let remote {
                    let client = try remote.get()
                    if LocalCommonMCP.names.contains(name) {
                        let object = try await LocalCommonMCP.call(name, arguments: args, domain: "athena", toolNames: names, client: client) { id in
                            try await AthenaMCP.call("system.get_task", args: ["taskId": id.uuidString], client: client)
                        }
                        return try LocalCommonMCP.result(object)
                    }
                    return try LocalCommonMCP.result(await AthenaMCP.call(name, args: args, client: client, context: context))
                }
                let value = try await dependencies.agentBridge.execute(command: AgentCommandRequest(commandID: name))
                return try JSONSerialization.data(withJSONObject: ["content": [["type": "text", "text": value.text]], "isError": false])
            } catch is CancellationError {
                // Отмена Swift-ожидания подавляется сеансом. Отменённая другим
                // запросом durable job — обычный доменный отказ CANCELLED.
                if Task.isCancelled { throw CancellationError() }
                return LocalCommonMCP.failure(LocalRuntimeFailure.cancelled)
            } catch { return LocalCommonMCP.failure(error) }
        }
    }
}

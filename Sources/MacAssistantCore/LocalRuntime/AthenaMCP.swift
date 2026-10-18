import CoreFoundation
import Foundation
import EcosystemLocalIPC
import EcosystemRuntimeSupport

/// Локальный MCP слой оставляет управление очередью в runtime. Синхронные
/// прежние 4 команды сохранены; start/get/cancel дают явный отменяемый цикл.
public enum AthenaMCP {
    public static let names = LocalAgentBridge.commands.map(\.id) + ["diagnostics.start", "system.get_task", "system.cancel_task", "diagnostics.history", "monitor.list", "monitor.get", "monitor.preview", "monitor.propose", "monitor.request_enable", "monitor.disable", "monitor.history"] + LocalAccessMCP.names + LocalInboxMCP.names
    private static func allowed(_ name: String) -> Set<String> {
        switch name {
        case "diagnostics.start": return ["idempotencyKey"]
        case "system.get_task", "system.cancel_task": return ["taskId"]
        case "diagnostics.history", "monitor.list": return ["offset"]
        case "monitor.preview", "monitor.propose": return ["rule"]
        case "monitor.history": return ["monitorId", "offset"]
        case "monitor.get", "monitor.request_enable", "monitor.disable": return ["monitorId"]
        default: return []
        }
    }
    public static var tools: [[String: Any]] {
        names.filter { !LocalAccessMCP.names.contains($0) && !LocalInboxMCP.names.contains($0) }.map { name in
            var properties: [String: Any] = [:]
            for key in allowed(name) {
                if key == "rule" {
                    properties[key] = ["type": "object", "additionalProperties": false, "properties": [
                        "name": ["type": "string", "minLength": 1, "maxLength": 128],
                        "metric": ["type": "string", "enum": ["cpu", "storage", "memoryPressure"]],
                        "intervalSeconds": ["type": "integer", "minimum": 60, "maximum": 86400],
                        "windowSamples": ["type": "integer", "minimum": 2, "maximum": 12],
                        "cooldownSeconds": ["type": "integer", "minimum": 60, "maximum": 86400],
                        "warning": ["type": "number", "minimum": 0, "maximum": 100],
                        "critical": ["type": "number", "minimum": 0, "maximum": 100],
                        "recovery": ["type": "number", "minimum": 0, "maximum": 100]]]
                } else if key == "offset" { properties[key] = ["type": "integer", "minimum": 0, "maximum": 1000000] }
                else if ["taskId", "monitorId"].contains(key) { properties[key] = ["type": "string", "format": "uuid"] }
                else { properties[key] = ["type": "string", "minLength": 1, "maxLength": 128] }
            }
            let required = allowed(name).subtracting(["offset", "idempotencyKey"]).subtracting(name == "monitor.history" ? ["monitorId"] : [])
            return ["name": name, "description": "Локальная операция Athena: " + name, "inputSchema": ["type": "object", "properties": properties, "required": required.sorted(), "additionalProperties": false]]
        } + LocalAccessMCP.tools + LocalInboxMCP.tools
    }
    public static func call(_ name: String, args: [String: Any], client: LocalRPCClient, context: MCPCallContext? = nil) async throws -> [String: Any] {
        if LocalInboxMCP.names.contains(name) { return try await LocalInboxMCP.call(name, args: args, client: client) }
        if LocalAccessMCP.names.contains(name) { return try await LocalAccessMCP.call(name, args: args, client: client) }
        guard names.contains(name), Set(args.keys).isSubset(of: allowed(name)) else { throw LocalRuntimeFailure.invalidRequest }
        if LocalAgentBridge.commands.contains(where: { $0.id == name }) || name == "diagnostics.start" {
            let key = args["idempotencyKey"] ?? UUID().uuidString
            guard let key = key as? String, !key.isEmpty, key.utf8.count <= 128 else { throw LocalRuntimeFailure.invalidRequest }
            let capability = name == "diagnostics.start" ? "diagnostics.run" : name
            let id: LocalTaskID = try await client.call("work.submit", AthenaSubmission(capability: capability, job: AthenaJob(), key: key))
            if name == "diagnostics.start" { return ["taskId": id.id.uuidString, "status": "accepted"] }
            let data = try await client.waitForData(id.id, cancelOnCancellation: false, onProgress: { progress in
                if let progress { await context?.progress(Double(progress.processed.value), progress.total.map { Double($0.value) }, "Выполнение") }
            })
            var result = try AthenaPublicResult.result(capability: capability, data: data); result["taskId"] = id.id.uuidString
            return result
        }
        if name == "system.get_task" || name == "system.cancel_task" {
            guard let text = args["taskId"] as? String, let id = UUID(uuidString: text) else { throw LocalRuntimeFailure.invalidRequest }
            if name == "system.cancel_task" { let _: LocalEmpty = try await client.call("task.cancel", LocalTaskID(id)); return ["taskId": text, "cancellationRequested": true] }
            let task: DurableTask = try await client.call("task.get", LocalTaskID(id))
            return try AthenaPublicResult.task(task)
        }
        var wire: [String: Any] = [:]
        if let offset = args["offset"] {
            guard let value = offset as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID(), value.doubleValue.rounded() == value.doubleValue, (0...1_000_000).contains(value.doubleValue) else { throw LocalRuntimeFailure.invalidRequest }
            wire["offset"] = value.intValue
        }
        if let value = args["monitorId"] {
            guard let text = value as? String, UUID(uuidString: text) != nil else { throw LocalRuntimeFailure.invalidRequest }; wire["monitorID"] = text
        }
        if name == "monitor.preview" || name == "monitor.propose" {
            guard let rule = args["rule"] as? [String: Any], Set(rule.keys).isSubset(of: ["name", "metric", "intervalSeconds", "windowSamples", "warning", "critical", "recovery", "cooldownSeconds"]) else { throw LocalRuntimeFailure.invalidRequest }
            var defaults = try AthenaPublicResult.object(MonitorRule())
            if let metric = rule["metric"] as? String {
                if metric == "storage" { defaults["critical"] = 90 }
                if metric == "memoryPressure" { defaults["warning"] = 1; defaults["critical"] = 2; defaults["recovery"] = 0 }
            }
            defaults.merge(rule) { _, value in value }
            let value = try JSONDecoder().decode(MonitorRule.self, from: JSONSerialization.data(withJSONObject: defaults)); try value.validate()
            wire["rule"] = defaults
        }
        let request = LocalRPCRequest(domain: "athena", operation: name, payload: try JSONSerialization.data(withJSONObject: wire))
        // Typed replies позволяют преобразовать даты без угадывания числовых полей.
        switch name {
        case "monitor.list": return try AthenaPublicResult.object(await client.call(name, LocalWire.decode(MonitorRequest.self, request.payload), as: MonitorPage.self))
        case "monitor.get", "monitor.propose", "monitor.disable": return try AthenaPublicResult.object(await client.call(name, LocalWire.decode(MonitorRequest.self, request.payload), as: MonitorEntry.self))
        case "monitor.preview": return try AthenaPublicResult.object(await client.call(name, LocalWire.decode(MonitorRequest.self, request.payload), as: MonitorRule.self))
        case "monitor.request_enable": return try AthenaPublicResult.object(await client.call(name, LocalWire.decode(MonitorRequest.self, request.payload), as: MonitorPlan.self))
        case "monitor.history": return try AthenaPublicResult.object(await client.call(name, LocalWire.decode(MonitorRequest.self, request.payload), as: MonitorHistoryPage.self))
        case "diagnostics.history":
            struct Reply: Decodable { let version: Int; let domain: String; let result: Data?; let error: LocalRuntimeFailure? }
            let reply = try LocalWire.decode(Reply.self, await client.exchange(LocalWire.encode(request)))
            guard reply.version == 1, reply.domain == "athena" else { throw LocalRuntimeFailure.invalidRequest }
            if let error = reply.error { throw error }; guard let result = reply.result else { throw LocalRuntimeFailure.operationFailed }
            return try JSONSerialization.jsonObject(with: result) as? [String: Any] ?? [:]
        default: throw LocalRuntimeFailure.invalidRequest
        }
    }
}

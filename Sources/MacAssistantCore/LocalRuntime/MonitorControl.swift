import Foundation
import EcosystemLocalIPC

/// Один typed endpoint используется GUI и MCP. Полномочие определяется
/// подписанным listener, а не ролью или approved=true внутри JSON.
enum MonitorControl {
    static func handle(store: MonitorStore, role: LocalRole, policy: LocalAccessPolicy? = nil, accessTicket: LocalAccessTicket? = nil, request: LocalRPCRequest) async throws -> Data {
        let keys: Set<String>
        switch request.operation {
        case "monitor.preview", "monitor.propose": keys = ["rule"]
        case "monitor.get", "monitor.request_enable", "monitor.disable": keys = ["monitorID"]
        case "monitor.history": keys = ["monitorID", "offset"]
        case "monitor.list": keys = ["offset"]
        case "monitor.pending": keys = []
        case "monitor.approve": keys = ["planID", "fingerprint"]
        default: throw LocalRuntimeFailure.denied
        }
        let value = try LocalWire.decode(MonitorRequest.self, request.payload, keys: keys)
        if let rule = value.rule {
            let object = try JSONSerialization.jsonObject(with: request.payload) as? [String: Any]
            guard let draft = object?["rule"] as? [String: Any], Set(draft.keys).isSubset(of: ["id", "name", "metric", "intervalSeconds", "windowSamples", "warning", "critical", "recovery", "cooldownSeconds"]) else { throw LocalRuntimeFailure.invalidRequest }
            try rule.validate()
        }
        switch request.operation {
        case "monitor.preview":
            guard let rule = value.rule else { throw LocalRuntimeFailure.invalidRequest }
            return try LocalWire.encode(rule)
        case "monitor.propose":
            guard let rule = value.rule else { throw LocalRuntimeFailure.invalidRequest }
            return try LocalWire.encode(try await store.propose(rule))
        case "monitor.list":
            let offset = value.offset ?? 0; guard (0...100_000).contains(offset) else { throw LocalRuntimeFailure.invalidRequest }
            let rows = await store.entries(); let items = Array(rows.dropFirst(offset).prefix(100))
            return try LocalWire.encode(MonitorPage(items: items, nextOffset: offset + items.count < rows.count ? offset + items.count : nil))
        case "monitor.history": return try LocalWire.encode(try await store.history(value.monitorID, offset: value.offset ?? 0))
        case "monitor.pending":
            guard role == .gui else { throw LocalRuntimeFailure.denied }; var plans: [MonitorPlan] = []
            for plan in await store.pending() {
                if let ticket = plan.accessTicket, let policy, (try? await policy.check(ticket)) == nil { continue }
                plans.append(plan)
            }
            return try LocalWire.encode(plans)
        case "monitor.approve":
            guard let id = value.planID, let fingerprint = value.fingerprint else { throw LocalRuntimeFailure.invalidRequest }
            if let plan = await store.pending().first(where: { $0.id == id }), let ticket = plan.accessTicket, let policy { _ = try await policy.check(ticket) }
            return try LocalWire.encode(try await store.approve(id, fingerprint: fingerprint, role: role))
        default:
            guard let id = value.monitorID else { throw LocalRuntimeFailure.invalidRequest }
            switch request.operation {
            case "monitor.get": return try LocalWire.encode(try await store.entry(id))
            case "monitor.request_enable": return try LocalWire.encode(try await store.requestEnable(id, accessTicket: accessTicket))
            case "monitor.disable": return try LocalWire.encode(try await store.disable(id))
            default: throw LocalRuntimeFailure.denied
            }
        }
    }
}

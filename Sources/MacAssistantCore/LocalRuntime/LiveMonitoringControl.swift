import Foundation
import EcosystemLocalIPC

private struct MonitoringSubscribeRequest: Codable, Sendable { let groups: Set<MonitoringGroup> }

/// GUI endpoints имеют отдельный строгий allowlist. Они не добавляются в MCP
/// capabilities и никогда не создают durable task на каждый снимок графика.
enum LiveMonitoringControl {
    static let maximumResponseBytes = 524_288

    static func handle(_ request: LocalRPCRequest, coordinator: MonitoringCoordinator) async throws -> Data {
        guard request.payload.count <= 4_096 else { throw LocalRuntimeFailure.invalidRequest }
        switch request.operation {
        case "monitoring.subscribe":
            let value = try decode(MonitoringSubscribeRequest.self, request.payload, keys: ["groups"])
            return try encode(await coordinator.subscribe(groups: value.groups))
        case "monitoring.renew":
            let value = try decode(LocalTaskID.self, request.payload, keys: ["id"])
            return try encode(await coordinator.renew(value.id))
        case "monitoring.unsubscribe":
            let value = try decode(LocalTaskID.self, request.payload, keys: ["id"])
            await coordinator.unsubscribe(value.id); return try encode(LocalEmpty())
        case "monitoring.snapshot":
            _ = try decode(LocalEmpty.self, request.payload, keys: [])
            return try encode(await coordinator.snapshot())
        case "monitoring.refreshApplications":
            _ = try decode(LocalEmpty.self, request.payload, keys: [])
            try await coordinator.refreshApplications(); return try encode(LocalEmpty())
        case "monitoring.history":
            let value = try decode(MonitoringHistoryQuery.self, request.payload,
                                            keys: ["group", "windowSeconds", "maximumPoints"])
            return try encode(await coordinator.history(value))
        default: throw LocalRuntimeFailure.denied
        }
    }

    private static func decode<T: Decodable>(_ type: T.Type, _ data: Data, keys: Set<String>) throws -> T {
        // LocalWire может бросить CocoaError при синтаксически неверном JSON.
        // Снаружи все ошибки формы должны иметь единый безопасный код запроса.
        do { return try LocalWire.decode(type, data, keys: keys) }
        catch { throw LocalRuntimeFailure.invalidRequest }
    }

    private static func encode<T: Encodable>(_ value: T) throws -> Data {
        let data = try LocalWire.encode(value)
        guard data.count <= maximumResponseBytes else { throw LocalRuntimeFailure.invalidRequest }
        return data
    }
}

/// Один протокол для установленного runtime и прямого debug backend.
/// Ошибка RPC не подменяется локальным чтением в обход роли или профиля.
public struct RemoteLiveMonitoringService: LiveMonitoringProviding {
    private let client: Result<LocalRPCClient, Error>
    public init(client: Result<LocalRPCClient, Error>) { self.client = client }
    public func subscribe(groups: Set<MonitoringGroup>) async throws -> MonitoringLease {
        try await client.get().call("monitoring.subscribe", MonitoringSubscribeRequest(groups: groups))
    }
    public func renew(_ id: UUID) async throws -> MonitoringLease {
        try await client.get().call("monitoring.renew", LocalTaskID(id))
    }
    public func unsubscribe(_ id: UUID) async throws {
        let _: LocalEmpty = try await client.get().call("monitoring.unsubscribe", LocalTaskID(id))
    }
    public func refreshApplications() async throws {
        let _: LocalEmpty = try await client.get().call("monitoring.refreshApplications", LocalEmpty())
    }
    public func snapshot() async throws -> MonitoringSnapshot {
        try await client.get().call("monitoring.snapshot", LocalEmpty())
    }
    public func history(_ query: MonitoringHistoryQuery) async throws -> [MonitoringHistoryPoint] {
        try await client.get().call("monitoring.history", query)
    }
}

/// Явно недоступная зависимость нужна preview/test-контейнерам: открытие UI
/// с заглушками не должно незаметно запускать реальный системный sampler.
public struct UnavailableLiveMonitoringService: LiveMonitoringProviding {
    public init() {}
    public func subscribe(groups: Set<MonitoringGroup>) async throws -> MonitoringLease { throw LocalRuntimeFailure.unavailable }
    public func renew(_ id: UUID) async throws -> MonitoringLease { throw LocalRuntimeFailure.unavailable }
    public func unsubscribe(_ id: UUID) async throws {}
    public func snapshot() async throws -> MonitoringSnapshot { throw LocalRuntimeFailure.unavailable }
    public func history(_ query: MonitoringHistoryQuery) async throws -> [MonitoringHistoryPoint] { throw LocalRuntimeFailure.unavailable }
}

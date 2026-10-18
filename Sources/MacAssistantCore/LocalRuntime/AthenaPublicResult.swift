import Foundation
import EcosystemLocalIPC
import EcosystemRuntimeSupport

/// Только явные read-only проекции. Ни запрос очереди, ни grants, ни пути
/// storage.scan не пересекают внешнюю границу. Все даты — UTC ISO 8601.
public enum AthenaPublicResult {
    static func object<T: Encodable>(_ value: T) throws -> [String: Any] {
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        return try JSONSerialization.jsonObject(with: encoder.encode(value)) as? [String: Any] ?? [:]
    }
    public static func result(capability: String, data: Data, now: Date = Date()) throws -> [String: Any] {
        switch capability {
        case "system.get_info": return try object(LocalWire.decode(SystemInfo.self, data))
        case "system.get_metrics":
            let metrics = try LocalWire.decode(SystemMetrics.self, data)
            var result = try object(metrics); result["quality"] = try object(metrics.quality(now: now)); return result
        case "diagnostics.run":
            let report = try LocalWire.decode(DiagnosticReport.self, data)
            var result = try object(report); result["quality"] = try object(report.metrics.quality(now: now)); return result
        case "storage.get_overview":
            let overview = try LocalWire.decode(StorageOverview.self, data)
            var result = try object(overview)
            result["stale"] = overview.capturedAt.map { now.timeIntervalSince($0) > 120 || now.timeIntervalSince($0) < -5 } ?? true
            result["complete"] = overview.totalBytes > 0
            return result
        default: throw LocalRuntimeFailure.denied
        }
    }
    public static func task(_ task: DurableTask) throws -> [String: Any] {
        var value: [String: Any] = ["taskId": task.id.uuidString, "capability": task.capabilityID,
            "status": task.status.rawValue, "createdAt": ISO8601DateFormatter().string(from: task.createdAt),
            "errorCode": task.errorCode?.rawValue as Any? ?? NSNull()]
        if let data = task.result { value["result"] = try result(capability: task.capabilityID, data: data) }
        return value
    }
}

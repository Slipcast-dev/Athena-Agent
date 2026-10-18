import CryptoKit
import Foundation
import EcosystemLocalIPC

public enum MonitorMetric: String, Codable, CaseIterable, Sendable { case cpu, storage, memoryPressure }
public enum MonitorStatus: String, Codable, Sendable { case normal, warmingUp, warning, critical, recovered, unavailable }
/// Конфигурация не содержит путей или действий над системой. Разрешение GUI
/// относится к точному fingerprint; новые предложения всегда выключены.
public struct MonitorRule: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID = UUID()
    public var name: String = "Локальная проверка"
    public var metric: MonitorMetric = .cpu
    public var intervalSeconds: Int = 300
    public var windowSamples: Int = 3
    public var warning: Double = 80
    public var critical: Double = 95
    public var recovery: Double = 75
    public var cooldownSeconds: Int = 900
    public init() {}
    public func validate() throws {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, name.utf8.count <= 128,
              (60...86_400).contains(intervalSeconds), (2...12).contains(windowSamples),
              (60...86_400).contains(cooldownSeconds), warning.isFinite, critical.isFinite, recovery.isFinite,
              recovery >= 0, recovery < warning, warning < critical,
              critical <= (metric == .memoryPressure ? 2 : 100) else { throw LocalRuntimeFailure.invalidRequest }
        if metric == .memoryPressure { guard recovery == 0, warning == 1, critical == 2 else { throw LocalRuntimeFailure.invalidRequest } }
    }
    public var fingerprint: String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        // Структура состоит только из конечных чисел; validate вызывается раньше.
        return (try? encoder.encode(self)).map { SHA256.hash(data: $0).map { String(format: "%02x", $0) }.joined() } ?? "invalid"
    }
}
public struct MonitorState: Codable, Equatable, Sendable {
    public var status: MonitorStatus = .warmingUp
    public var samples: [Double] = []
    public var lastSampleAt: Date?
    public var incident: MonitorStatus?
    public var lastNotificationAt: Date?
    public init() {}
}
public struct MonitorEntry: Codable, Identifiable, Sendable {
    public var rule: MonitorRule
    public var enabled: Bool = false
    public var approvedRevision: String?
    public var state = MonitorState()
    public var id: UUID { rule.id }
}
public struct MonitorPlan: Codable, Identifiable, Sendable {
    public let id: UUID
    public let monitorID: UUID
    public let fingerprint: String
    public let expiresAt: Date
    public var accessTicket: LocalAccessTicket? = nil
    public var consumed: Bool = false
}
public struct MonitorEvent: Codable, Identifiable, Sendable {
    public let id: UUID
    public let monitorID: UUID
    public let capturedAt: Date
    public let previous: MonitorStatus
    public let status: MonitorStatus
    public let value: Double?
    public let notificationEligible: Bool
}
public struct MonitorPage: Codable, Sendable { public let items: [MonitorEntry]; public let nextOffset: Int? }
public struct MonitorHistoryPage: Codable, Sendable { public let items: [MonitorEvent]; public let nextOffset: Int? }
public struct MonitorRequest: Codable, Sendable {
    public var rule: MonitorRule?
    public var monitorID: UUID?
    public var planID: UUID?
    public var fingerprint: String?
    public var offset: Int?
    public init(rule: MonitorRule? = nil, monitorID: UUID? = nil, planID: UUID? = nil, fingerprint: String? = nil, offset: Int? = nil) {
        self.rule = rule; self.monitorID = monitorID; self.planID = planID; self.fingerprint = fingerprint; self.offset = offset
    }
}

/// Чистый автомат: consecutive window требует устойчивой нагрузки. Недоступность
/// разрывает окно, но не забывает инцидент; после неё требуется новое окно нормы.
public enum MonitorEvaluator {
    public static func value(_ metrics: SystemMetrics, metric: MonitorMetric, now: Date) -> Double? {
        guard !metrics.quality(now: now).stale else { return nil }
        switch metric {
        case .cpu: return metrics.quality(now: now).cpu == .available ? metrics.cpuUsagePercent : nil
        case .storage: return metrics.storageUsagePercent
        case .memoryPressure:
            switch metrics.memoryPressure { case .normal: return 0; case .warning: return 1; case .critical: return 2; case nil: return nil }
        }
    }
    public static func step(rule: MonitorRule, state old: MonitorState, value: Double?, now: Date, warmingUp: Bool = false) -> (MonitorState, MonitorEvent?) {
        var state = old
        if let last = state.lastSampleAt, now.timeIntervalSince(last) > Double(rule.intervalSeconds * 2) || now < last {
            state.samples = []; state.status = .warmingUp
        }
        let previous = old.status
        state.lastSampleAt = now
        if let value, value.isFinite, (0...(rule.metric == .memoryPressure ? 2 : 100)).contains(value) {
            state.samples.append(value); state.samples = Array(state.samples.suffix(rule.windowSamples))
            if state.samples.count < rule.windowSamples { state.status = .warmingUp }
            else if state.samples.allSatisfy({ $0 >= rule.critical }) { state.status = .critical; state.incident = .critical }
            else if state.samples.allSatisfy({ $0 >= rule.warning }) { state.status = .warning; state.incident = .warning }
            else if state.incident != nil {
                if state.samples.allSatisfy({ $0 <= rule.recovery }) { state.status = .recovered; state.incident = nil }
                else { state.status = state.incident ?? .warmingUp }
            } else { state.status = .normal }
        } else { state.samples = []; state.status = warmingUp ? .warmingUp : .unavailable }
        guard state.status != previous else { return (state, nil) }
        let significant = [.warning, .critical, .recovered, .unavailable].contains(state.status)
        let elapsed = state.lastNotificationAt.map { now.timeIntervalSince($0) } ?? .infinity
        let notify = significant && (elapsed >= Double(rule.cooldownSeconds) || state.status == .recovered || state.status == .critical && old.incident != .critical)
        if notify { state.lastNotificationAt = now }
        return (state, MonitorEvent(id: UUID(), monitorID: rule.id, capturedAt: now, previous: previous, status: state.status, value: value, notificationEligible: notify))
    }
}

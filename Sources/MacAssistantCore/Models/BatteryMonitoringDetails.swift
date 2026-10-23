import Foundation

public enum BatteryPowerSource: String, Codable, Sendable { case battery, external, offline }
public enum BatteryHealth: String, Codable, Sendable { case good, fair, poor }
public enum BatteryCondition: String, Codable, Sendable { case checkBattery, permanentFailure }

/// Дополнение optional сохраняет чтение снимков старого runtime. Здесь только
/// allowlist показателей: серийные номера и полный IORegistry не передаются GUI.
public struct BatteryMonitoringDetails: Codable, Equatable, Sendable {
    public var powerSource: MonitoringMetric<BatteryPowerSource> = .init()
    public var fullyCharged: MonitoringMetric<Bool> = .init()
    public var health: MonitoringMetric<BatteryHealth> = .init()
    public var condition: MonitoringMetric<BatteryCondition> = .init()
    public var minutesToEmpty: MonitoringMetric<Int> = .init()
    public var minutesToFull: MonitoringMetric<Int> = .init()
    public var voltageVolts: MonitoringMetric<Double> = .init()
    public var currentAmperes: MonitoringMetric<Double> = .init()
    public var adapterWatts: MonitoringMetric<Double> = .init()
    public var retainedCapacityPercent: MonitoringMetric<Double> = .init()
    public init() {}

    var valid: Bool {
        let minutes = [minutesToEmpty, minutesToFull].allSatisfy { $0.value.map { (0...43_200).contains($0) } ?? true }
        let bounded: [(MonitoringMetric<Double>, ClosedRange<Double>)] = [
            (voltageVolts, 0...100), (currentAmperes, -100...100),
            (adapterWatts, 0...1000), (retainedCapacityPercent, 0...200)]
        return minutes && bounded.allSatisfy { field, range in field.value.map { $0.isFinite && range.contains($0) } ?? true }
    }
}

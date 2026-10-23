import Foundation
import IOKit
import IOKit.ps

/// Синхронный read-only адаптер вызывается в utility task координатора.
/// Any/CF объекты остаются внутри вызова; через actor передаётся только DTO.
struct BatteryMonitoringReader: Sendable {
    func read() throws -> BatteryMonitoringMetrics {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else {
            throw CocoaError(.fileReadUnknown)
        }
        var batteries: [[String: Any]] = []
        for source in sources {
            // Ошибка чтения описания не означает отсутствие батареи: иначе
            // временный сбой API ошибочно выглядел бы как настольный Mac.
            guard let row = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                  let type = row[kIOPSTypeKey] as? String else { throw CocoaError(.fileReadCorruptFile) }
            guard type == kIOPSInternalBatteryType else { continue }
            batteries.append(row)
        }
        var registry: [String: Any] = [:]
        // Дополнительные поля читаем только для единственной внутренней батареи:
        // иначе первый matching service мог бы принадлежать другому источнику.
        if batteries.count == 1, Self.boolean(batteries[0][kIOPSIsPresentKey]) == true {
            let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
            if service != 0 {
                defer { IOObjectRelease(service) }
                for key in ["CycleCount", "Voltage", "Amperage"] {
                    registry[key] = IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
                }
            }
        }
        let adapter = IOPSCopyExternalPowerAdapterDetails()?.takeRetainedValue() as? [String: Any] ?? [:]
        return Self.decode(batteries: batteries, registry: registry, adapter: adapter)
    }

    /// CFBoolean является NSNumber: проверка typeID предотвращает превращение
    /// true в один цикл/вольт. Дробные, бесконечные и переполненные числа отвергаем.
    static func number(_ value: Any?) -> Double? {
        guard let value = value as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID() else { return nil }
        let result = value.doubleValue
        return result.isFinite && result.rounded() == result ? result : nil
    }
    static func boolean(_ value: Any?) -> Bool? {
        guard let value = value as? NSNumber, CFGetTypeID(value) == CFBooleanGetTypeID() else { return nil }
        return value.boolValue
    }
    private static func bounded(_ value: Any?, _ range: ClosedRange<Double>) -> Double? {
        number(value).flatMap { range.contains($0) ? $0 : nil }
    }

    /// IOPMPowerSource::setAmperage публикует signed int как OSNumber(32 bits).
    /// CFNumber может вернуть unsigned two's complement; знак восстанавливаем
    /// лишь для целого 32/64-bit представления, затем ограничиваем физический диапазон.
    static func registryCurrent(_ value: Any?) -> Double? {
        guard let value = value as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID() else { return nil }
        let text = value.stringValue
        if let signed = Int64(text), (-100_000...100_000).contains(signed) { return Double(signed) }
        guard let raw = UInt64(text) else { return nil }
        let signed: Int64
        if raw <= UInt64(UInt32.max) { signed = Int64(Int32(bitPattern: UInt32(raw))) }
        else { signed = Int64(bitPattern: raw) }
        return (-100_000...100_000).contains(signed) ? Double(signed) : nil
    }

    static func decode(batteries: [[String: Any]], registry: [String: Any] = [:], adapter: [String: Any] = [:]) -> BatteryMonitoringMetrics {
        // Нет внутреннего источника — нормальное состояние настольного Mac.
        guard !batteries.isEmpty else { return .init(present: .init(false)) }
        // Неподдерживаемую топологию не усредняем с ложной точностью.
        guard batteries.count == 1 else { return .init(present: .init(nil, state: .unsupported)) }
        let row = batteries[0]
        let present = boolean(row[kIOPSIsPresentKey])
        guard present == true else { return .init(present: .init(present)) }
        var details = BatteryMonitoringDetails()
        switch row[kIOPSPowerSourceStateKey] as? String {
        case kIOPSBatteryPowerValue: details.powerSource = .init(.battery)
        case kIOPSACPowerValue: details.powerSource = .init(.external)
        case kIOPSOffLineValue: details.powerSource = .init(.offline)
        default: break
        }
        let charging = boolean(row[kIOPSIsChargingKey])
        details.fullyCharged = .init(boolean(row[kIOPSIsChargedKey]))
        switch row[kIOPSBatteryHealthKey] as? String {
        case kIOPSGoodValue: details.health = .init(.good)
        case kIOPSFairValue: details.health = .init(.fair)
        case kIOPSPoorValue: details.health = .init(.poor)
        default: break
        }
        switch row[kIOPSBatteryHealthConditionKey] as? String {
        case kIOPSCheckBatteryValue: details.condition = .init(.checkBattery)
        case kIOPSPermanentFailureValue: details.condition = .init(.permanentFailure)
        default: break
        }
        // IOPS capacities используют одну шкалу, часто проценты, а не mAh.
        // Сырые AppleRawMaxCapacity/DesignCapacity из IORegistry сюда не смешиваем.
        let maximum = bounded(row[kIOPSMaxCapacityKey], 1...1_000_000)
        let current = bounded(row[kIOPSCurrentCapacityKey], 0...1_000_000)
        let charge = current.flatMap { value in maximum.flatMap { value <= $0 ? value / $0 * 100 : nil } }
        if let maximum, let design = bounded(row[kIOPSDesignCapacityKey], 1...1_000_000), maximum / design <= 2 {
            details.retainedCapacityPercent = .init(maximum / design * 100)
        }
        func estimate(_ key: String, valid: Bool) -> MonitoringMetric<Int> {
            guard valid else { return .init() }
            if number(row[key]) == -1 { return .init(nil, state: .warmingUp) }
            return .init(bounded(row[key], 0...43_200).map(Int.init))
        }
        details.minutesToEmpty = estimate(kIOPSTimeToEmptyKey, valid: details.powerSource.value == .battery && charging == false)
        details.minutesToFull = estimate(kIOPSTimeToFullChargeKey, valid: charging == true)
        // IOPSKeys.h: Voltage mV, Current mA, Temperature °C. Для registry
        // допускаем только документированные Voltage/Amperage; Temperature
        // драйвера может быть в иных единицах и намеренно не используется.
        details.voltageVolts = .init((bounded(row[kIOPSVoltageKey], 0...100_000) ?? bounded(registry["Voltage"], 0...100_000)).map { $0 / 1000 })
        details.currentAmperes = .init((bounded(row[kIOPSCurrentKey], -100_000...100_000) ?? registryCurrent(registry["Amperage"])).map { $0 / 1000 })
        if details.powerSource.value == .external {
            details.adapterWatts = .init(bounded(adapter[kIOPSPowerAdapterWattsKey], 0...1000))
        }
        return .init(present: .init(true), chargePercent: .init(charge), charging: .init(charging),
            cycleCount: .init(bounded(registry["CycleCount"], 0...1_000_000).map(Int.init)),
            temperatureCelsius: .init(bounded(row[kIOPSTemperatureKey], -100...200)), details: details)
    }
}

public actor BatteryMonitoringCollector: MonitoringCollecting {
    public nonisolated let group: MonitoringGroup = .battery
    private let read: @Sendable () throws -> BatteryMonitoringMetrics
    public init() { read = { try BatteryMonitoringReader().read() } }
    init(read: @escaping @Sendable () throws -> BatteryMonitoringMetrics) { self.read = read }
    public func collect(reset: Bool) async throws -> MonitoringCollection {
        try Task.checkCancellation()
        let metrics = try read()
        try Task.checkCancellation()
        return MonitoringCollection(payload: .battery(metrics))
    }
}

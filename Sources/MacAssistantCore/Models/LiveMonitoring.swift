import Foundation

/// Каналы имеют собственную частоту: обход процессов и диска не должен
/// выполняться каждую секунду вместе с быстрыми счётчиками CPU/RAM/network.
public enum MonitoringGroup: String, Codable, CaseIterable, Sendable {
    case cpu, network, memory, processes, disk, battery, applications

    public var interval: TimeInterval {
        switch self {
        case .cpu, .network, .memory: 1
        case .processes: 5
        case .disk: 10
        case .battery: 15
        case .applications: 300
        }
    }
}

/// Доступность относится к конкретному полю. Nil никогда не обозначает ноль.
/// Timestamp/интервал принадлежат содержащей поле выборке одного канала.
public struct MonitoringMetric<Value: Codable & Equatable & Sendable>: Codable, Equatable, Sendable {
    public let state: MeasurementState
    public let value: Value?

    public init(_ value: Value? = nil, state: MeasurementState = .unavailable) {
        self.value = value
        self.state = value == nil ? (state == .available ? .unavailable : state) : .available
    }
}

public struct CPUMonitoringMetrics: Codable, Equatable, Sendable {
    public let totalPercent: MonitoringMetric<Double>
    public let userPercent: MonitoringMetric<Double>
    public let systemPercent: MonitoringMetric<Double>
    public let cores: [MonitoringMetric<Double>]
    public let identity: ProcessorIdentity?

    public init(totalPercent: MonitoringMetric<Double>, userPercent: MonitoringMetric<Double> = .init(),
                systemPercent: MonitoringMetric<Double> = .init(), cores: [MonitoringMetric<Double>] = [], identity: ProcessorIdentity? = nil) {
        self.totalPercent = totalPercent; self.userPercent = userPercent
        self.systemPercent = systemPercent; self.cores = cores; self.identity = identity
    }
}

public struct MemoryMonitoringMetrics: Codable, Equatable, Sendable {
    public let totalBytes: MonitoringMetric<UInt64>
    public let usedBytes: MonitoringMetric<UInt64>
    public let availableBytes: MonitoringMetric<UInt64>
    public let wiredBytes: MonitoringMetric<UInt64>
    public let compressedBytes: MonitoringMetric<UInt64>
    public let cachedBytes: MonitoringMetric<UInt64>
    public let swapUsedBytes: MonitoringMetric<UInt64>
    public let pressure: MonitoringMetric<MemoryPressure>

    public init(totalBytes: MonitoringMetric<UInt64>, usedBytes: MonitoringMetric<UInt64>,
                availableBytes: MonitoringMetric<UInt64>, wiredBytes: MonitoringMetric<UInt64> = .init(),
                compressedBytes: MonitoringMetric<UInt64> = .init(), cachedBytes: MonitoringMetric<UInt64> = .init(),
                swapUsedBytes: MonitoringMetric<UInt64> = .init(), pressure: MonitoringMetric<MemoryPressure> = .init()) {
        self.totalBytes = totalBytes; self.usedBytes = usedBytes; self.availableBytes = availableBytes
        self.wiredBytes = wiredBytes; self.compressedBytes = compressedBytes; self.cachedBytes = cachedBytes
        self.swapUsedBytes = swapUsedBytes; self.pressure = pressure
    }
}

/// Счётчики накоплены с момента создания/сброса интерфейса, не за сессию GUI.
/// Адреса/маршруты и Wi-Fi добавляются отдельно и никогда не входят в историю.
public struct NetworkInterfaceDetails: Codable, Equatable, Sendable {
    public let index: UInt32
    public let up: Bool
    public let running: Bool
    public let loopback: Bool
    public let pointToPoint: Bool
    public let mtu: UInt32
    public let receivedBytes: UInt64
    public let sentBytes: UInt64
    public let receivedPackets: UInt64
    public let sentPackets: UInt64
    public let receivedErrors: UInt64
    public let sentErrors: UInt64
    public init(index: UInt32, up: Bool, running: Bool, loopback: Bool, pointToPoint: Bool,
                mtu: UInt32, receivedBytes: UInt64, sentBytes: UInt64, receivedPackets: UInt64,
                sentPackets: UInt64, receivedErrors: UInt64, sentErrors: UInt64) {
        self.index = index; self.up = up; self.running = running; self.loopback = loopback
        self.pointToPoint = pointToPoint; self.mtu = mtu; self.receivedBytes = receivedBytes
        self.sentBytes = sentBytes; self.receivedPackets = receivedPackets; self.sentPackets = sentPackets
        self.receivedErrors = receivedErrors; self.sentErrors = sentErrors
    }
}

public struct NetworkInterfaceMetrics: Codable, Equatable, Sendable {
    public let id: String
    public let receivedBytesPerSecond: MonitoringMetric<Double>
    public let sentBytesPerSecond: MonitoringMetric<Double>
    public let details: NetworkInterfaceDetails?
    public let configuration: NetworkInterfaceConfiguration?

    public init(id: String, receivedBytesPerSecond: MonitoringMetric<Double>, sentBytesPerSecond: MonitoringMetric<Double>,
                details: NetworkInterfaceDetails? = nil, configuration: NetworkInterfaceConfiguration? = nil) {
        self.id = id; self.receivedBytesPerSecond = receivedBytesPerSecond
        self.sentBytesPerSecond = sentBytesPerSecond; self.details = details; self.configuration = configuration
    }
}

public struct ProcessMemoryMetrics: Codable, Equatable, Sendable {
    public let pid: Int32
    public let name: String
    public let footprintBytes: MonitoringMetric<UInt64>
    public let applicationID: String?
    public let applicationName: String?

    public init(pid: Int32, name: String, footprintBytes: MonitoringMetric<UInt64>,
                applicationID: String? = nil, applicationName: String? = nil) {
        self.pid = pid; self.name = name; self.footprintBytes = footprintBytes
        self.applicationID = applicationID; self.applicationName = applicationName
    }
}

/// Покрытие обхода не равно количеству строк: RPC отдаёт максимум 512 самых
/// крупных процессов, но отдельно сообщает пропуски и усечение результата.
public struct ProcessMemorySummary: Codable, Equatable, Sendable {
    public let observed: Int
    public let readable: Int
    public let unavailable: Int
    public let omitted: Int
    public let enumerationComplete: Bool
    public init(observed: Int, readable: Int, unavailable: Int, omitted: Int, enumerationComplete: Bool) {
        self.observed = observed; self.readable = readable; self.unavailable = unavailable
        self.omitted = omitted; self.enumerationComplete = enumerationComplete
    }
}

public struct DiskVolumeMetrics: Codable, Equatable, Sendable {
    /// Стабильный неприватный идентификатор; URL/имя тома сюда не передаются.
    public let id: String
    public let totalBytes: MonitoringMetric<UInt64>
    public let freeBytes: MonitoringMetric<UInt64>
    public let availableForImportantUsageBytes: MonitoringMetric<UInt64>
    public let name: String?
    public let mountPath: String?
    public let readOnly: Bool?
    var capacityValid: Bool {
        guard let total = totalBytes.value, let free = freeBytes.value else { return true }
        return free <= total
    }
    public var usedBytes: MonitoringMetric<UInt64> {
        guard let total = totalBytes.value, let free = freeBytes.value, free <= total else { return .init() }
        return .init(total - free)
    }

    public init(id: String, totalBytes: MonitoringMetric<UInt64>, freeBytes: MonitoringMetric<UInt64>,
                availableForImportantUsageBytes: MonitoringMetric<UInt64> = .init(),
                name: String? = nil, mountPath: String? = nil, readOnly: Bool? = nil) {
        self.id = id; self.totalBytes = totalBytes; self.freeBytes = freeBytes
        self.availableForImportantUsageBytes = availableForImportantUsageBytes
        self.name = name; self.mountPath = mountPath; self.readOnly = readOnly
    }
}

public struct BatteryMonitoringMetrics: Codable, Equatable, Sendable {
    public let present: MonitoringMetric<Bool>
    public let chargePercent: MonitoringMetric<Double>
    public let charging: MonitoringMetric<Bool>
    public let cycleCount: MonitoringMetric<Int>
    public let temperatureCelsius: MonitoringMetric<Double>
    public let details: BatteryMonitoringDetails?

    public init(present: MonitoringMetric<Bool>, chargePercent: MonitoringMetric<Double> = .init(),
                charging: MonitoringMetric<Bool> = .init(), cycleCount: MonitoringMetric<Int> = .init(),
                temperatureCelsius: MonitoringMetric<Double> = .init(), details: BatteryMonitoringDetails? = nil) {
        self.present = present; self.chargePercent = chargePercent; self.charging = charging
        self.cycleCount = cycleCount; self.temperatureCelsius = temperatureCelsius; self.details = details
    }
}

/// Отдельные варианты не позволяют выдать сетевой снимок за процессорный.
/// Детали интерфейсов/приложений хранятся только в последнем снимке, не в истории.
public enum MonitoringPayload: Codable, Equatable, Sendable {
    case cpu(CPUMonitoringMetrics)
    case memory(MemoryMonitoringMetrics)
    case network([NetworkInterfaceMetrics], summary: NetworkMonitoringSummary? = nil)
    case processes([ProcessMemoryMetrics], summary: ProcessMemorySummary? = nil)
    case disk([DiskVolumeMetrics])
    case battery(BatteryMonitoringMetrics)
    case applications(ApplicationInventoryMetrics)

    public var group: MonitoringGroup {
        switch self {
        case .cpu: .cpu
        case .memory: .memory
        case .network: .network
        case .processes: .processes
        case .disk: .disk
        case .battery: .battery
        case .applications: .applications
        }
    }

    /// Ограничение формы выполняется ДО сохранения в RAM, не только на RPC.
    /// JSONEncoder одновременно отвергает NaN/Infinity во всех вложенных полях.
    func validated() -> Bool {
        switch self {
        case .cpu(let value):
            guard value.cores.count <= 256 else { return false }
            if let identity = value.identity {
                guard identity.logicalCoreCount == value.cores.count,
                      identity.name.map({ $0.utf8.count <= 256 }) ?? true else { return false }
            }
            let fields = [value.totalPercent, value.userPercent, value.systemPercent] + value.cores
            guard fields.allSatisfy({ $0.value.map { $0.isFinite && (0...100).contains($0) } ?? true }) else { return false }
        case .network(let rows, let summary):
            guard rows.count <= 32, Set(rows.map(\.id)).count == rows.count,
                  rows.allSatisfy({ Self.validSeriesID($0.id) &&
                      [$0.receivedBytesPerSecond, $0.sentBytesPerSecond].allSatisfy {
                          $0.value.map { $0.isFinite && $0 >= 0 } ?? true
                      } }) else { return false }
            guard rows.allSatisfy({ $0.configuration?.valid ?? true }) else { return false }
            if let summary { guard summary.valid, summary.observedInterfaces == rows.count + summary.omittedInterfaces else { return false } }
        case .processes(let rows, let summary):
            guard rows.count <= 512, Set(rows.map(\.pid)).count == rows.count,
                  rows.allSatisfy({ $0.pid > 0 && $0.name.utf8.count <= 256 &&
                      ($0.applicationName.map { $0.utf8.count <= 256 } ?? true) &&
                      ($0.applicationID.map(Self.validSeriesID) ?? true) &&
                      (($0.applicationID == nil) == ($0.applicationName == nil)) }) else { return false }
            if let summary {
                guard (0...4096).contains(summary.observed), summary.readable >= 0,
                      summary.unavailable >= 0, (0...summary.observed).contains(summary.omitted),
                      summary.readable <= summary.observed,
                      summary.unavailable == summary.observed - summary.readable,
                      rows.count + summary.omitted == summary.observed else { return false }
            }
        case .disk(let rows):
            guard rows.count <= 32, Set(rows.map(\.id)).count == rows.count,
                  rows.allSatisfy({ Self.validSeriesID($0.id) && ($0.name.map { $0.utf8.count <= 256 } ?? true) &&
                      ($0.mountPath.map { $0.utf8.count <= 1024 } ?? true) &&
                      ($0.capacityValid) }) else { return false }
        case .battery(let value):
            // Отсутствующая/неподдерживаемая батарея не может содержать
            // измеренный нулевой заряд или аппаратные данные другого источника.
            if value.present.value != true {
                guard value.chargePercent.value == nil, value.charging.value == nil,
                      value.cycleCount.value == nil, value.temperatureCelsius.value == nil,
                      value.details == nil else { return false }
            }
            guard value.chargePercent.value.map({ $0.isFinite && (0...100).contains($0) }) ?? true else { return false }
            guard value.temperatureCelsius.value.map({ $0.isFinite && (-100...200).contains($0) }) ?? true,
                  value.cycleCount.value.map({ (0...1_000_000).contains($0) }) ?? true,
                  value.details?.valid ?? true else { return false }
        case .applications(let data): guard data.valid else { return false }
        case .memory: break
        }
        guard let data = try? JSONEncoder().encode(self) else { return false }
        return data.count <= 262_144
    }

    private static func validSeriesID(_ id: String) -> Bool {
        // ASCII allowlist исключает пути и адреса вида IPv4:port/IPv6; источник
        // передаёт opaque ID тома или имя интерфейса, а не пользовательское имя.
        !id.isEmpty && id.utf8.count <= 64 && id.utf8.allSatisfy {
            (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || [45, 46, 95].contains($0)
        }
    }

    /// История содержит только числовые графики. Имена процессов/PID, пути и
    /// адреса сети сюда не попадают; индекс core остаётся индексом логического CPU.
    var graphValues: [String: Double] {
        var values: [String: Double] = [:]
        switch self {
        case .cpu(let data):
            values["total"] = data.totalPercent.value
            values["user"] = data.userPercent.value
            values["system"] = data.systemPercent.value
            for (index, field) in data.cores.enumerated() { values["core.\(index)"] = field.value }
        case .memory(let data):
            values["used"] = data.usedBytes.value.map(Double.init)
            values["compressed"] = data.compressedBytes.value.map(Double.init)
            values["swapUsed"] = data.swapUsedBytes.value.map(Double.init)
        case .network(let rows, _):
            for row in rows {
                values[row.id + ".received"] = row.receivedBytesPerSecond.value
                values[row.id + ".sent"] = row.sentBytesPerSecond.value
            }
        case .disk(let rows):
            for row in rows { values[row.id + ".free"] = row.freeBytes.value.map(Double.init) }
        case .battery(let data): values["charge"] = data.chargePercent.value
        case .processes, .applications: break
        }
        return values
    }
}

public struct MonitoringSample: Codable, Equatable, Sendable {
    public let group: MonitoringGroup
    public let capturedAt: Date
    public let intervalSeconds: TimeInterval?
    public let state: MeasurementState
    public let payload: MonitoringPayload?
    public let stale: Bool
}

public struct MonitoringSnapshot: Codable, Equatable, Sendable {
    public let suspended: Bool
    public let samples: [MonitoringSample]
}

public struct MonitoringHistoryPoint: Codable, Equatable, Sendable {
    public let capturedAt: Date
    public let state: MeasurementState
    public let values: [String: Double]
}

public struct MonitoringLease: Codable, Equatable, Sendable {
    public let id: UUID
    public let expiresAt: Date
}

public struct MonitoringHistoryQuery: Codable, Equatable, Sendable {
    public let group: MonitoringGroup
    public let windowSeconds: Int
    public let maximumPoints: Int

    public init(group: MonitoringGroup, windowSeconds: Int = 60, maximumPoints: Int = 120) {
        self.group = group; self.windowSeconds = windowSeconds; self.maximumPoints = maximumPoints
    }

    var valid: Bool { [60, 300, 900].contains(windowSeconds) && (2...120).contains(maximumPoints) }
}

/// Общий seam для debug-реализации и GUI RPC. Сборщики не доступны View напрямую.
public protocol LiveMonitoringProviding: Sendable {
    func subscribe(groups: Set<MonitoringGroup>) async throws -> MonitoringLease
    func renew(_ id: UUID) async throws -> MonitoringLease
    func unsubscribe(_ id: UUID) async throws
    func snapshot() async throws -> MonitoringSnapshot
    func history(_ query: MonitoringHistoryQuery) async throws -> [MonitoringHistoryPoint]
    func refreshApplications() async throws
}
public extension LiveMonitoringProviding {
    func refreshApplications() async throws { throw CocoaError(.featureUnsupported) }
}

import Darwin
import Foundation
import EcosystemLocalIPC

/// UInt32 сохраняет реальную разрядность Mach CPU ticks. Уменьшение счётчика
/// означает новый baseline, а не почти 2^32 ticks искусственной нагрузки.
public struct ProcessorTicks: Equatable, Sendable {
    public let user: UInt32
    public let system: UInt32
    public let idle: UInt32
    public let nice: UInt32
    public init(user: UInt32, system: UInt32, idle: UInt32, nice: UInt32) {
        self.user = user; self.system = system; self.idle = idle; self.nice = nice
    }
}

public struct ProcessorIdentity: Codable, Equatable, Sendable {
    public let name: String?
    public let physicalCoreCount: Int?
    public let logicalCoreCount: Int
    public let performanceCoreCount: Int?
    public let efficiencyCoreCount: Int?

    public init(name: String?, physicalCoreCount: Int?, logicalCoreCount: Int,
                performanceCoreCount: Int? = nil, efficiencyCoreCount: Int? = nil) {
        self.name = name; self.physicalCoreCount = physicalCoreCount; self.logicalCoreCount = logicalCoreCount
        self.performanceCoreCount = performanceCoreCount; self.efficiencyCoreCount = efficiencyCoreCount
    }
}

public protocol ProcessorCounterReading: Sendable {
    func read() throws -> [ProcessorTicks]
    func identity(logicalCoreCount: Int) -> ProcessorIdentity?
}
public extension ProcessorCounterReading {
    func identity(logicalCoreCount: Int) -> ProcessorIdentity? { nil }
}

/// Только счётчики Mach/sysctl, без shell, sudo, SMC/IOReport или private API.
public struct MachProcessorCounterReader: ProcessorCounterReading {
    public init() {}
    public func read() throws -> [ProcessorTicks] {
        let host = mach_host_self()
        defer { mach_port_deallocate(mach_task_self_, host) }
        var processors: natural_t = 0
        var pointer: processor_info_array_t?
        var count: mach_msg_type_number_t = 0
        let code = host_processor_info(host, PROCESSOR_CPU_LOAD_INFO, &processors, &pointer, &count)
        // Mach выделяет массив; освобождаем весь returned count и на ветках ошибки.
        defer {
            if let pointer {
                vm_deallocate(mach_task_self_, vm_address_t(UInt(bitPattern: pointer)),
                              vm_size_t(Int(count) * MemoryLayout<integer_t>.stride))
            }
        }
        guard code == KERN_SUCCESS, let pointer, processors > 0, processors <= 256,
              Int(count) >= Int(processors) * Int(CPU_STATE_MAX) else { throw LocalRuntimeFailure.operationFailed }
        return (0..<Int(processors)).map { core in
            let start = core * Int(CPU_STATE_MAX)
            return ProcessorTicks(user: UInt32(bitPattern: pointer[start + Int(CPU_STATE_USER)]),
                system: UInt32(bitPattern: pointer[start + Int(CPU_STATE_SYSTEM)]),
                idle: UInt32(bitPattern: pointer[start + Int(CPU_STATE_IDLE)]),
                nice: UInt32(bitPattern: pointer[start + Int(CPU_STATE_NICE)]))
        }
    }

    public func identity(logicalCoreCount: Int) -> ProcessorIdentity? {
        let physical = integer("hw.physicalcpu").flatMap { $0 > 0 && $0 <= logicalCoreCount ? $0 : nil }
        // P/E показываем только при явных именах perflevel и согласованной сумме.
        // Порядок логических CPU в Mach НЕ объявляется порядком этих кластеров.
        var performance: Int?, efficiency: Int?
        for index in 0..<2 {
            let name = string("hw.perflevel\(index).name")?.lowercased()
            let cores = integer("hw.perflevel\(index).physicalcpu")
            if name == "performance" { performance = cores }
            if name == "efficiency" { efficiency = cores }
        }
        let topologyConfirmed: Bool
        if let performance, let efficiency, let physical {
            topologyConfirmed = performance > 0 && efficiency > 0 && performance + efficiency == physical
        } else { topologyConfirmed = false }
        if !topologyConfirmed { performance = nil; efficiency = nil }
        return ProcessorIdentity(name: string("machdep.cpu.brand_string"), physicalCoreCount: physical,
            logicalCoreCount: logicalCoreCount, performanceCoreCount: performance, efficiencyCoreCount: efficiency)
    }

    private func integer(_ name: String) -> Int? {
        var value: Int32 = 0, size = MemoryLayout<Int32>.size
        guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return nil }
        return Int(value)
    }
    private func string(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0, size <= 256 else { return nil }
        var bytes = [CChar](repeating: 0, count: size)
        let code = bytes.withUnsafeMutableBufferPointer { sysctlbyname(name, $0.baseAddress, &size, nil, 0) }
        guard code == 0 else { return nil }
        return String(validatingCString: bytes)?.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

public enum ProcessorLoadCalculator {
    public static func calculate(previous: [ProcessorTicks], current: [ProcessorTicks]) -> CPUMonitoringMetrics? {
        guard !current.isEmpty, current.count <= 256, previous.count == current.count else { return nil }
        var totalUser: UInt64 = 0, totalSystem: UInt64 = 0, totalTicks: UInt64 = 0
        var cores: [MonitoringMetric<Double>] = []
        for (before, after) in zip(previous, current) {
            guard after.user >= before.user, after.system >= before.system,
                  after.idle >= before.idle, after.nice >= before.nice else { return nil }
            // Nice относится к пользовательской работе. UInt64 достаточно для
            // суммы четырёх UInt32 delta × 256 ядер без арифметического overflow.
            let user = UInt64(after.user - before.user) + UInt64(after.nice - before.nice)
            let system = UInt64(after.system - before.system)
            let ticks = user + system + UInt64(after.idle - before.idle)
            totalUser += user; totalSystem += system; totalTicks += ticks
            cores.append(ticks == 0 ? .init(state: .warmingUp) : .init(Double(user + system) / Double(ticks) * 100))
        }
        guard totalTicks > 0 else { return nil }
        // Общая нагрузка взвешена по ticks, а не по количеству отдельных ratio.
        return CPUMonitoringMetrics(totalPercent: .init(Double(totalUser + totalSystem) / Double(totalTicks) * 100),
            userPercent: .init(Double(totalUser) / Double(totalTicks) * 100),
            systemPercent: .init(Double(totalSystem) / Double(totalTicks) * 100), cores: cores)
    }
}

public actor ProcessorMonitoringCollector: MonitoringCollecting {
    public nonisolated let group = MonitoringGroup.cpu
    private let reader: any ProcessorCounterReading
    private var previous: [ProcessorTicks]?
    private var identity: ProcessorIdentity?
    private var identityLoaded = false
    public init(reader: any ProcessorCounterReading = MachProcessorCounterReader()) { self.reader = reader }

    public func collect(reset: Bool) async throws -> MonitoringCollection {
        do {
            try Task.checkCancellation()
            if reset { previous = nil }
            let current = try reader.read()
            guard !current.isEmpty, current.count <= 256 else { throw LocalRuntimeFailure.operationFailed }
            try Task.checkCancellation()
            if !identityLoaded || previous?.count != current.count {
                identity = reader.identity(logicalCoreCount: current.count); identityLoaded = true
            }
            let load = previous.flatMap { ProcessorLoadCalculator.calculate(previous: $0, current: current) }
            previous = current
            let payload = CPUMonitoringMetrics(
                totalPercent: load?.totalPercent ?? .init(state: .warmingUp),
                userPercent: load?.userPercent ?? .init(state: .warmingUp),
                systemPercent: load?.systemPercent ?? .init(state: .warmingUp),
                cores: load?.cores ?? current.map { _ in .init(state: .warmingUp) }, identity: identity)
            return MonitoringCollection(state: load == nil ? .warmingUp : .available, payload: .cpu(payload))
        } catch {
            previous = nil; throw error
        }
    }
}

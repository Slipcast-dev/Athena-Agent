import Darwin
import Foundation
import Dispatch
import EcosystemLocalIPC

/// Mach возвращает страницы разных категорий, не независимые доли пирога.
/// File-backed пересекается с inactive, поэтому складывать их нельзя.
public struct MemoryCounters: Sendable {
    public let total: UInt64
    public let pageSize: UInt64
    public let free: UInt64
    public let inactive: UInt64
    public let wired: UInt64
    public let compressed: UInt64
    public let fileBacked: UInt64
    public let swapUsed: UInt64?
    public let pressure: MemoryPressure?
    public init(total: UInt64, pageSize: UInt64, free: UInt64, inactive: UInt64,
                wired: UInt64, compressed: UInt64, fileBacked: UInt64,
                swapUsed: UInt64?, pressure: MemoryPressure?) {
        self.total = total; self.pageSize = pageSize; self.free = free; self.inactive = inactive
        self.wired = wired; self.compressed = compressed; self.fileBacked = fileBacked
        self.swapUsed = swapUsed; self.pressure = pressure
    }
}
public protocol MemoryCounterReading: Sendable { func read() throws -> MemoryCounters }

public struct MachMemoryCounterReader: MemoryCounterReading {
    public init() {}
    public func read() throws -> MemoryCounters {
        let host = mach_host_self()
        defer { mach_port_deallocate(mach_task_self_, host) }
        var statistics = vm_statistics64_data_t()
        let expected = MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size
        var count = mach_msg_type_number_t(expected)
        let code = withUnsafeMutablePointer(to: &statistics) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: expected) {
                host_statistics64(host, HOST_VM_INFO64, $0, &count)
            }
        }
        guard code == KERN_SUCCESS, count >= expected else { throw LocalRuntimeFailure.operationFailed }
        var swap = xsw_usage(), swapSize = MemoryLayout<xsw_usage>.size
        let swapOK = sysctlbyname("vm.swapusage", &swap, &swapSize, nil, 0) == 0 && swapSize == MemoryLayout<xsw_usage>.size
        var pressure: UInt32 = 0, pressureSize = MemoryLayout<UInt32>.size
        let pressureOK = sysctlbyname("kern.memorystatus_vm_pressure_level", &pressure, &pressureSize, nil, 0) == 0
            && pressureSize == MemoryLayout<UInt32>.size
        return MemoryCounters(total: ProcessInfo.processInfo.physicalMemory, pageSize: UInt64(vm_kernel_page_size),
            free: UInt64(statistics.free_count), inactive: UInt64(statistics.inactive_count),
            wired: UInt64(statistics.wire_count), compressed: UInt64(statistics.compressor_page_count),
            fileBacked: UInt64(statistics.external_page_count), swapUsed: swapOK ? swap.xsu_used : nil,
            pressure: pressureOK ? Self.decodePressure(pressure) : nil)
    }

    /// Этот optional sysctl не является контрактом SDK. XNU handler возвращает
    /// DISPATCH flags, а НЕ внутренние уровни 0/1/2/3. Неизвестные значения или
    /// отсутствие ключа дают unavailable; процент RAM не подменяет pressure.
    /// Источник: apple-oss-distributions/xnu/bsd/kern/kern_memorystatus_notify.c,
    /// sysctl_memorystatus_vm_pressure_level / convert_internal_pressure_level_to_dispatch_level.
    static func decodePressure(_ value: UInt32) -> MemoryPressure? {
        switch UInt(value) {
        case DispatchSource.MemoryPressureEvent.normal.rawValue: .normal
        case DispatchSource.MemoryPressureEvent.warning.rawValue: .warning
        case DispatchSource.MemoryPressureEvent.critical.rawValue: .critical
        default: nil
        }
    }
}

public enum MemoryMetricsCalculator {
    public static func calculate(_ value: MemoryCounters) throws -> MemoryMonitoringMetrics {
        guard value.total > 0, value.pageSize > 0 else { throw LocalRuntimeFailure.operationFailed }
        func bytes(_ pages: UInt64) throws -> UInt64 {
            let result = pages.multipliedReportingOverflow(by: value.pageSize)
            guard !result.overflow, result.partialValue <= value.total else { throw LocalRuntimeFailure.operationFailed }
            return result.partialValue
        }
        let free = try bytes(value.free), inactive = try bytes(value.inactive)
        let available = free.addingReportingOverflow(inactive)
        guard !available.overflow, available.partialValue <= value.total else { throw LocalRuntimeFailure.operationFailed }
        // Сохраняем определение старого systemMetrics: доступно = free+inactive,
        // занято = total-доступно. Это оценка, а не точная копия Activity Monitor.
        return MemoryMonitoringMetrics(totalBytes: .init(value.total), usedBytes: .init(value.total - available.partialValue),
            availableBytes: .init(available.partialValue), wiredBytes: .init(try bytes(value.wired)),
            compressedBytes: .init(try bytes(value.compressed)), cachedBytes: .init(try bytes(value.fileBacked)),
            swapUsedBytes: .init(value.swapUsed), pressure: .init(value.pressure))
    }
}

public actor MemoryMonitoringCollector: MonitoringCollecting {
    public nonisolated let group = MonitoringGroup.memory
    private let reader: any MemoryCounterReading
    public init(reader: any MemoryCounterReading = MachMemoryCounterReader()) { self.reader = reader }
    public func collect(reset: Bool) async throws -> MonitoringCollection {
        try Task.checkCancellation()
        let value = try MemoryMetricsCalculator.calculate(reader.read())
        try Task.checkCancellation()
        return MonitoringCollection(payload: .memory(value))
    }
}

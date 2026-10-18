import Foundation

/// Динамические показатели системы. Значения объёма измеряются в байтах,
/// а проценты хранятся в диапазоне от 0 до 100 для исключения неоднозначности UI.
public struct SystemMetrics: Codable, Equatable, Sendable {
    public let capturedAt: Date
    /// Необязательные поля сохраняют чтение старых результатов очереди.
    public let cpuState: MeasurementState?
    public let cpuIntervalMilliseconds: Double?
    public let cpuUsagePercent: Double?
    public let totalMemoryBytes: UInt64
    public let usedMemoryBytes: UInt64
    public let availableMemoryBytes: UInt64?
    public let memoryPressure: MemoryPressure?
    public let totalStorageBytes: UInt64
    public let availableStorageBytes: UInt64

    public init(
        capturedAt: Date = .now,
        cpuState: MeasurementState? = nil,
        cpuIntervalMilliseconds: Double? = nil,
        cpuUsagePercent: Double?,
        totalMemoryBytes: UInt64,
        usedMemoryBytes: UInt64,
        availableMemoryBytes: UInt64?,
        memoryPressure: MemoryPressure?,
        totalStorageBytes: UInt64,
        availableStorageBytes: UInt64
    ) {
        self.capturedAt = capturedAt
        self.cpuState = cpuState
        self.cpuIntervalMilliseconds = cpuIntervalMilliseconds
        self.cpuUsagePercent = cpuUsagePercent
        self.totalMemoryBytes = totalMemoryBytes
        self.usedMemoryBytes = usedMemoryBytes
        self.availableMemoryBytes = availableMemoryBytes
        self.memoryPressure = memoryPressure
        self.totalStorageBytes = totalStorageBytes
        self.availableStorageBytes = availableStorageBytes
    }

    /// Защита от некорректных системных данных: при нулевой ёмкости возвращается
    /// `nil`, вместо вводящего в заблуждение процента.
    public var storageUsagePercent: Double? {
        guard totalStorageBytes > 0 else { return nil }
        // APFS способен вернуть доступное пространство больше логической ёмкости
        // из-за снимков или особенностей тома. Не допускаем переполнения UInt64.
        let used = totalStorageBytes >= availableStorageBytes
            ? totalStorageBytes - availableStorageBytes
            : 0
        return (Double(used) / Double(totalStorageBytes)) * 100
    }

    /// Высокое использование памяти само по себе не является неисправностью:
    /// macOS использует свободную RAM как кэш. Поэтому это только показатель,
    /// а предупреждения создаются лишь при наличии надёжного сигнала давления.
    public var memoryUsagePercent: Double? {
        guard totalMemoryBytes > 0 else { return nil }
        return (Double(usedMemoryBytes) / Double(totalMemoryBytes)) * 100
    }
}

public enum MemoryPressure: String, Codable, CaseIterable, Sendable {
    case normal
    case warning
    case critical
}

/// «Нет измерения» и «норма» различаются: отсутствие pressure не доказывает
/// отсутствие проблемы. Возраст вычисляется при чтении, а не хранится навсегда.
public enum MeasurementState: String, Codable, Sendable { case available, warmingUp, unavailable, unsupported }
public struct MeasurementQuality: Codable, Equatable, Sendable {
    public let capturedAt: Date
    public let ageSeconds: Double
    public let stale: Bool
    public let complete: Bool
    public let cpu: MeasurementState
    public let memory: MeasurementState
    public let memoryPressure: MeasurementState
    public let storage: MeasurementState
}
public extension SystemMetrics {
    func quality(now: Date = Date()) -> MeasurementQuality {
        let age = now.timeIntervalSince(capturedAt)
        let cpu = cpuUsagePercent.map { $0.isFinite && (0...100).contains($0) ? MeasurementState.available : .unavailable } ?? cpuState ?? .warmingUp
        let memory: MeasurementState = totalMemoryBytes > 0 && usedMemoryBytes <= totalMemoryBytes && availableMemoryBytes != nil ? .available : .unavailable
        let storage: MeasurementState = totalStorageBytes > 0 ? .available : .unavailable
        return MeasurementQuality(capturedAt: capturedAt, ageSeconds: max(0, age), stale: age > 120 || age < -5,
            complete: cpu == .available && memory == .available && storage == .available,
            cpu: cpu, memory: memory, memoryPressure: memoryPressure == nil ? .unsupported : .available, storage: storage)
    }
}

import Foundation

/// Базовый адаптер RAM и ёмкости тома; CPU-ветка сохраняет совместимость
/// явных зависимостей, а live-фабрика использует ProcessorMonitoringCollector.
/// Live RAM/processes/network/battery подключены отдельными сборщиками.
/// Отсутствующие поля остаются unavailable, не заполняются выдуманным нулём.
public actor BasicMonitoringCollector: MonitoringCollecting {
    public nonisolated let group: MonitoringGroup
    private var system: any SystemInformationProviding
    private let makeSystem: @Sendable () -> any SystemInformationProviding

    public init(group: MonitoringGroup, makeSystem: @escaping @Sendable () -> any SystemInformationProviding = { SystemInformationService() }) {
        self.group = group; self.makeSystem = makeSystem; self.system = makeSystem()
    }

    public func collect(reset: Bool) async throws -> MonitoringCollection {
        try Task.checkCancellation()
        if reset { system = makeSystem() }
        let metrics = try await system.systemMetrics()
        try Task.checkCancellation()
        switch group {
        case .cpu:
            let valid = metrics.cpuUsagePercent.flatMap { $0.isFinite && (0...100).contains($0) ? $0 : nil }
            let state: MeasurementState = valid != nil ? .available : (metrics.cpuState == .warmingUp || metrics.cpuState == nil ? .warmingUp : .unavailable)
            return MonitoringCollection(state: state, payload: .cpu(CPUMonitoringMetrics(
                totalPercent: MonitoringMetric(valid, state: state))))
        case .memory:
            let valid = metrics.totalMemoryBytes > 0 && metrics.usedMemoryBytes <= metrics.totalMemoryBytes && metrics.availableMemoryBytes != nil
            guard valid else { return MonitoringCollection(state: .unavailable) }
            return MonitoringCollection(payload: .memory(MemoryMonitoringMetrics(
                totalBytes: .init(metrics.totalMemoryBytes), usedBytes: .init(metrics.usedMemoryBytes),
                availableBytes: .init(metrics.availableMemoryBytes), pressure: .init(metrics.memoryPressure))))
        case .disk:
            guard metrics.totalStorageBytes > 0 else { return MonitoringCollection(state: .unavailable) }
            // Legacy systemMetrics предпочитает important-usage, а не физически
            // свободное место. Не меняем семантику поля при переносе в новую модель.
            return MonitoringCollection(payload: .disk([DiskVolumeMetrics(id: "system",
                totalBytes: .init(metrics.totalStorageBytes), freeBytes: .init(),
                availableForImportantUsageBytes: .init(metrics.availableStorageBytes))]))
        default: return MonitoringCollection(state: .unavailable)
        }
    }
}

public extension MonitoringCoordinator {
    static func makeLive() -> MonitoringCoordinator {
        // Отдельные сборщики защищают baseline CPU как от других каналов,
        // так и от существующих background monitor/MCP операций.
        MonitoringCoordinator(collectors: [ProcessorMonitoringCollector(),
            MemoryMonitoringCollector(), ProcessMemoryCollector(), NetworkMonitoringCollector(), DiskCapacityCollector(), ApplicationInventoryCollector(), BatteryMonitoringCollector()])
    }
}

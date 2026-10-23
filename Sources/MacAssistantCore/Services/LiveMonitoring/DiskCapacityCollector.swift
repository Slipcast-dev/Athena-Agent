import CryptoKit
import Foundation
import EcosystemLocalIPC

public protocol DiskVolumeReading: Sendable { func read() throws -> [DiskVolumeMetrics] }
public struct MountedDiskVolumeReader: DiskVolumeReading {
    public init() {}
    public func read() throws -> [DiskVolumeMetrics] {
        guard let mounted = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: [.volumeIsLocalKey],
            options: [.skipHiddenVolumes]) else { throw LocalRuntimeFailure.operationFailed }
        var rows: [DiskVolumeMetrics] = [], identifiers = Set<String>()
        // Системный том показываем и при скрытом mount entry. Сетевые тома
        // исключены: их capacity lookup может зависеть от удалённого сервера.
        for url in [URL(fileURLWithPath: "/")] + mounted {
            try Task.checkCancellation()
            guard (try? url.resourceValues(forKeys: [.volumeIsLocalKey]).volumeIsLocal) == true else { continue }
            let values = try? url.resourceValues(forKeys: [.volumeUUIDStringKey, .volumeNameKey, .volumeTotalCapacityKey,
                .volumeAvailableCapacityKey, .volumeIsReadOnlyKey])
            let identity = values?.volumeUUIDString ?? url.path
            let id = SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined()
            guard identifiers.insert(id).inserted else { continue }
            let total = values?.volumeTotalCapacity.flatMap { $0 > 0 ? UInt64($0) : nil }
            let free = values?.volumeAvailableCapacity.flatMap { $0 >= 0 ? UInt64($0) : nil }
                .flatMap { value in total.map { value <= $0 ? value : nil } ?? nil }
            // Optional important-usage не должен лишать нас базовой ёмкости
            // на файловой системе, где этот конкретный ключ не поддерживается.
            let importantValues = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            let important = importantValues?.volumeAvailableCapacityForImportantUsage.flatMap { $0 >= 0 ? UInt64($0) : nil }
            rows.append(DiskVolumeMetrics(id: id, totalBytes: .init(total), freeBytes: .init(free),
                availableForImportantUsageBytes: .init(important), name: Self.bounded(values?.volumeName ?? url.lastPathComponent, maximum: 256),
                mountPath: Self.bounded(url.path, maximum: 1024), readOnly: values?.volumeIsReadOnly))
            if rows.count == 32 { break }
        }
        guard !rows.isEmpty else { throw LocalRuntimeFailure.operationFailed }
        return rows
    }
    static func bounded(_ value: String, maximum: Int) -> String {
        var result = ""
        for character in value {
            guard result.utf8.count + String(character).utf8.count <= maximum else { break }
            result.append(character)
        }
        return result
    }
}
public actor DiskCapacityCollector: MonitoringCollecting {
    public nonisolated let group = MonitoringGroup.disk
    private let reader: any DiskVolumeReading
    public init(reader: any DiskVolumeReading = MountedDiskVolumeReader()) { self.reader = reader }
    public func collect(reset: Bool) async throws -> MonitoringCollection {
        try Task.checkCancellation()
        let rows = try reader.read()
        try Task.checkCancellation()
        return MonitoringCollection(state: rows.contains { $0.totalBytes.value != nil } ? .available : .unavailable, payload: .disk(rows))
    }
}

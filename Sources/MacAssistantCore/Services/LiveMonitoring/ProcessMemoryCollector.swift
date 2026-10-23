import CryptoKit
import Darwin
import Foundation
import EcosystemLocalIPC

public struct ProcessMemoryReading: Sendable {
    public let rows: [ProcessMemoryMetrics]
    public let enumerationComplete: Bool
    public init(rows: [ProcessMemoryMetrics], enumerationComplete: Bool) {
        self.rows = rows; self.enumerationComplete = enumerationComplete
    }
}
public protocol ProcessMemoryReadingProviding: Sendable { func read() throws -> ProcessMemoryReading }

/// libproc не требует task_for_pid/sudo. Отказ SIP/TCC или исчезновение процесса
/// — локальный пропуск footprint, а не ноль и не повод обходить защиту.
public struct LibprocMemoryReader: ProcessMemoryReadingProviding {
    public init() {}
    public func read() throws -> ProcessMemoryReading {
        let estimate = proc_listallpids(nil, 0)
        guard estimate > 0 else { throw LocalRuntimeFailure.operationFailed }
        let capacity = min(4096, Int(estimate) + 256)
        var pids = [Int32](repeating: 0, count: capacity)
        let count = pids.withUnsafeMutableBytes { proc_listallpids($0.baseAddress, Int32($0.count)) }
        guard count > 0 else { throw LocalRuntimeFailure.operationFailed }
        var rows: [ProcessMemoryMetrics] = []
        for pid in Set(pids.prefix(min(Int(count), capacity))).sorted() where pid > 0 {
            try Task.checkCancellation()
            var usage = rusage_info_v2()
            let code = withUnsafeMutablePointer(to: &usage) { pointer in
                pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                    proc_pid_rusage(pid, RUSAGE_INFO_V2, $0)
                }
            }
            var name = [CChar](repeating: 0, count: 256)
            let length = name.withUnsafeMutableBytes { proc_name(pid, $0.baseAddress, UInt32($0.count)) }
            name[name.count - 1] = 0
            let label = length > 0 ? String(cString: name) : String(pid)
            // PROC_PIDPATHINFO_MAXSIZE = 4*MAXPATHLEN в proc_info.h;
            // Swift не импортирует этот составной C macro.
            var path = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
            let pathLength = path.withUnsafeMutableBytes { proc_pidpath(pid, $0.baseAddress, UInt32($0.count)) }
            path[path.count - 1] = 0
            let candidate = pathLength > 0 ? Self.application(executablePath: String(cString: path)) : nil
            // Между footprint и именем PID может быть переиспользован. Повторно
            // сверяем время рождения; несовпадение не приписывает память новому app.
            var confirmation = rusage_info_v2()
            let confirmed = withUnsafeMutablePointer(to: &confirmation) { pointer in
                pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                    proc_pid_rusage(pid, RUSAGE_INFO_V2, $0)
                }
            } == 0 && code == 0 && confirmation.ri_proc_start_abstime == usage.ri_proc_start_abstime
            let app = confirmed ? candidate : nil
            rows.append(ProcessMemoryMetrics(pid: pid, name: Self.bounded(label),
                footprintBytes: confirmed ? .init(usage.ri_phys_footprint) : .init(),
                applicationID: app?.id, applicationName: app?.name))
        }
        return ProcessMemoryReading(rows: rows, enumerationComplete: Int(count) < capacity)
    }

    /// Группируем только по явному внешнему .app в пути executable, включая
    /// вложенные Helper.app. Сам путь не передаётся в RPC и не читается с диска;
    /// hash различает два одноимённых приложения. XPC вне bundle остаётся процессом.
    static func application(executablePath: String) -> (id: String, name: String)? {
        guard executablePath.hasPrefix("/"), !executablePath.contains("/../") else { return nil }
        let parts = executablePath.split(separator: "/")
        guard let index = parts.firstIndex(where: { $0.hasSuffix(".app") }), index + 1 < parts.count else { return nil }
        let root = "/" + parts[...index].joined(separator: "/")
        let digest = SHA256.hash(data: Data(root.utf8)).map { String(format: "%02x", $0) }.joined()
        return (digest, bounded(String(parts[index].dropLast(4))))
    }
    private static func bounded(_ value: String) -> String {
        // Лимит протокола задан в UTF-8, поэтому prefix(256) Characters недостаточен.
        var output = ""
        for character in value {
            guard output.utf8.count + String(character).utf8.count <= 256 else { break }
            output.append(character)
        }
        return output
    }
}

public actor ProcessMemoryCollector: MonitoringCollecting {
    public nonisolated let group = MonitoringGroup.processes
    private let reader: any ProcessMemoryReadingProviding
    public init(reader: any ProcessMemoryReadingProviding = LibprocMemoryReader()) { self.reader = reader }
    public func collect(reset: Bool) async throws -> MonitoringCollection {
        try Task.checkCancellation()
        let value = try reader.read()
        guard value.rows.count <= 4096 else { throw LocalRuntimeFailure.operationFailed }
        let readable = value.rows.filter { $0.footprintBytes.value != nil }.count
        // Ограничение payload не делает обход «полным»: summary сохраняет число
        // невключённых строк. Крупнейшие известные footprint идут первыми.
        let rows = value.rows.sorted {
            if $0.footprintBytes.value != $1.footprintBytes.value {
                if $0.footprintBytes.value == nil { return false }
                if $1.footprintBytes.value == nil { return true }
                return ($0.footprintBytes.value ?? 0) > ($1.footprintBytes.value ?? 0)
            }
            return $0.pid < $1.pid
        }.prefix(512)
        try Task.checkCancellation()
        return MonitoringCollection(payload: .processes(Array(rows), summary: ProcessMemorySummary(
            observed: value.rows.count, readable: readable, unavailable: value.rows.count - readable,
            omitted: value.rows.count - rows.count, enumerationComplete: value.enumerationComplete)))
    }
}

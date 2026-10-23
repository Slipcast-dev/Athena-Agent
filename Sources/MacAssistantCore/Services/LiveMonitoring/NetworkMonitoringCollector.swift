import Darwin
import Foundation
import EcosystemLocalIPC

/// generation — время административного изменения интерфейса. В сочетании с
/// index/name оно не позволяет продолжить baseline после большинства reconnect.
public struct NetworkCounters: Sendable {
    public let id: String
    public let generation: String
    public let details: NetworkInterfaceDetails
    public init(id: String, generation: String, details: NetworkInterfaceDetails) {
        self.id = id; self.generation = generation; self.details = details
    }
}
public protocol NetworkCounterReading: Sendable { func read() throws -> [NetworkCounters] }

/// getifaddrs.ifa_data использует 32-битные byte counters и оборачивается после
/// 4 GiB. NET_RT_IFLIST2 предоставляет if_data64 без этой потери разрядности.
public struct RouteNetworkCounterReader: NetworkCounterReading {
    public init() {}
    public func read() throws -> [NetworkCounters] {
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, 0]
        for _ in 0..<3 {
            var count = 0
            let estimated = mib.withUnsafeMutableBufferPointer { sysctl($0.baseAddress, u_int($0.count), nil, &count, nil, 0) }
            guard estimated == 0, count > 0, count <= 1_048_576 else { throw LocalRuntimeFailure.operationFailed }
            var data = Data(count: count)
            let code = data.withUnsafeMutableBytes { bytes in
                mib.withUnsafeMutableBufferPointer { sysctl($0.baseAddress, u_int($0.count), bytes.baseAddress, &count, nil, 0) }
            }
            // Сеть могла измениться между двумя sysctl; ограниченно повторяем
            // только ENOMEM, остальные ошибки не скрываются пустым списком.
            if code != 0, errno == ENOMEM { continue }
            guard code == 0, count <= data.count else { throw LocalRuntimeFailure.operationFailed }
            data.count = count
            return try Self.decode(data)
        }
        throw LocalRuntimeFailure.operationFailed
    }

    static func decode(_ data: Data) throws -> [NetworkCounters] {
        var rows: [NetworkCounters] = [], offset = 0
        while offset < data.count {
            guard data.count - offset >= 4 else { throw LocalRuntimeFailure.operationFailed }
            let length = data.withUnsafeBytes { Int($0.loadUnaligned(fromByteOffset: offset, as: UInt16.self)) }
            let version = data[offset + 2], type = data[offset + 3]
            guard length >= 4, length <= data.count - offset, version == RTM_VERSION else {
                throw LocalRuntimeFailure.operationFailed
            }
            defer { offset += length }
            guard type == RTM_IFINFO2 else { continue }
            guard length >= MemoryLayout<if_msghdr2>.size else { throw LocalRuntimeFailure.operationFailed }
            // Route records не обещают Swift alignment. loadUnaligned безопасен
            // для тривиального C struct после проверки всех размеров сообщения.
            let message = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: if_msghdr2.self) }
            var name = [CChar](repeating: 0, count: Int(IF_NAMESIZE))
            let index = UInt32(message.ifm_index)
            guard if_indextoname(index, &name) != nil else { continue } // удалён во время чтения
            let counter = message.ifm_data, flags = message.ifm_flags
            rows.append(NetworkCounters(id: String(cString: name),
                generation: "\(counter.ifi_lastchange.tv_sec).\(counter.ifi_lastchange.tv_usec)",
                details: NetworkInterfaceDetails(index: index, up: flags & IFF_UP != 0,
                    running: flags & IFF_RUNNING != 0, loopback: flags & IFF_LOOPBACK != 0,
                    pointToPoint: flags & IFF_POINTOPOINT != 0, mtu: counter.ifi_mtu,
                    receivedBytes: counter.ifi_ibytes, sentBytes: counter.ifi_obytes,
                    receivedPackets: counter.ifi_ipackets, sentPackets: counter.ifi_opackets,
                    receivedErrors: counter.ifi_ierrors, sentErrors: counter.ifi_oerrors)))
            guard rows.count <= 256 else { throw LocalRuntimeFailure.operationFailed }
        }
        guard Set(rows.map(\.id)).count == rows.count else { throw LocalRuntimeFailure.operationFailed }
        // При очень большом числе VPN interfaces сначала сохраняем активные.
        // UI не должен утверждать полноту: протокол ограничен 32 интерфейсами.
        return rows.sorted {
            if $0.details.up != $1.details.up { return $0.details.up }
            return $0.id < $1.id
        }
    }
}

public enum NetworkRateCalculator {
    public static func calculate(previous: [NetworkCounters]?, current: [NetworkCounters], elapsed: TimeInterval?) -> [NetworkInterfaceMetrics] {
        var old: [String: NetworkCounters] = [:]
        for row in previous ?? [] { old[row.id] = row }
        return current.map { row in
            let current = row.details
            var received: MonitoringMetric<Double> = .init(state: current.up ? .warmingUp : .unavailable)
            var sent = received
            // Дельты разных направлений принимаем вместе: rollback хотя бы
            // одного счётчика означает reset обоих, не отрицательную скорость.
            if current.up, let before = old[row.id], before.details.up,
               before.details.index == current.index, before.generation == row.generation,
               let elapsed, elapsed.isFinite, elapsed > 0, elapsed <= 5,
               current.receivedBytes >= before.details.receivedBytes,
               current.sentBytes >= before.details.sentBytes {
                let rx = Double(current.receivedBytes - before.details.receivedBytes) / elapsed
                let tx = Double(current.sentBytes - before.details.sentBytes) / elapsed
                if rx.isFinite && tx.isFinite { received = .init(rx); sent = .init(tx) }
            }
            return NetworkInterfaceMetrics(id: row.id, receivedBytesPerSecond: received,
                                           sentBytesPerSecond: sent, details: current)
        }
    }
}

public actor NetworkMonitoringCollector: MonitoringCollecting {
    public nonisolated let group = MonitoringGroup.network
    private let reader: any NetworkCounterReading
    private let clock: MonitoringClock
    private let environmentReader: any NetworkEnvironmentReading
    private var environment: (value: NetworkEnvironment, time: TimeInterval)?
    private var previous: (rows: [NetworkCounters], time: TimeInterval)?
    public init(reader: any NetworkCounterReading = RouteNetworkCounterReader(), clock: MonitoringClock = .live,
                environmentReader: any NetworkEnvironmentReading = SystemNetworkEnvironmentReader()) {
        self.reader = reader; self.clock = clock; self.environmentReader = environmentReader
    }
    public func collect(reset: Bool) async throws -> MonitoringCollection {
        if reset { previous = nil; environment = nil }
        do {
            try Task.checkCancellation()
            let rows = try reader.read(), now = clock.now().monotonic
            guard rows.count <= 256 else { throw LocalRuntimeFailure.operationFailed }
            if environment == nil || now - (environment?.time ?? now) >= 5 {
                environment = (environmentReader.read(), now)
            }
            let config = environment?.value ?? NetworkEnvironment()
            let preferred = Set([config.primaryIPv4, config.primaryIPv6].compactMap { $0 })
            let selected = Array(rows.sorted {
                if preferred.contains($0.id) != preferred.contains($1.id) { return preferred.contains($0.id) }
                if $0.details.up != $1.details.up { return $0.details.up }
                return $0.id < $1.id
            }.prefix(32))
            let metrics = NetworkRateCalculator.calculate(previous: previous?.rows, current: selected,
                                                           elapsed: previous.map { now - $0.time })
            let enriched = metrics.map { NetworkInterfaceMetrics(id: $0.id, receivedBytesPerSecond: $0.receivedBytesPerSecond,
                sentBytesPerSecond: $0.sentBytesPerSecond, details: $0.details, configuration: config.configurations[$0.id]) }
            try Task.checkCancellation()
            previous = (rows, now)
            let warming = metrics.contains { $0.receivedBytesPerSecond.state == .warmingUp }
            let available = metrics.contains { $0.receivedBytesPerSecond.value != nil }
            return MonitoringCollection(state: warming && !available ? .warmingUp : .available, payload: .network(enriched, summary: NetworkMonitoringSummary(
                observedInterfaces: rows.count, omittedInterfaces: rows.count - selected.count,
                configurationCapturedAt: config.capturedAt, primaryIPv4: config.primaryIPv4, primaryIPv6: config.primaryIPv6,
                routerIPv4: .init(config.routerIPv4), routerIPv6: .init(config.routerIPv6), dnsServers: .init(config.dnsServers))))
        } catch { previous = nil; environment = nil; throw error }
    }
}

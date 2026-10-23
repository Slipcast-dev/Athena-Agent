import Foundation

public struct WiFiMonitoringMetrics: Codable, Equatable, Sendable {
    public let powered: Bool
    public let rssiDBm: Int?
    public let noiseDBm: Int?
    public let channel: Int?
    public let linkMegabitsPerSecond: Double?
    public init(powered: Bool, rssiDBm: Int? = nil, noiseDBm: Int? = nil,
                channel: Int? = nil, linkMegabitsPerSecond: Double? = nil) {
        self.powered = powered; self.rssiDBm = rssiDBm; self.noiseDBm = noiseDBm
        self.channel = channel; self.linkMegabitsPerSecond = linkMegabitsPerSecond
    }
    var valid: Bool {
        (rssiDBm.map { (-127 ... -1).contains($0) } ?? true) &&
        (noiseDBm.map { (-127 ... -1).contains($0) } ?? true) &&
        (channel.map { (1...1024).contains($0) } ?? true) &&
        (linkMegabitsPerSecond.map { $0.isFinite && $0 > 0 && $0 <= 1_000_000 } ?? true)
    }
}

public struct NetworkInterfaceConfiguration: Codable, Equatable, Sendable {
    public let addresses: MonitoringMetric<[String]>
    public let wifi: WiFiMonitoringMetrics?
    public init(addresses: MonitoringMetric<[String]>, wifi: WiFiMonitoringMetrics? = nil) {
        self.addresses = addresses; self.wifi = wifi
    }
    var valid: Bool {
        (addresses.value.map { $0.count <= 32 && $0.allSatisfy { $0.utf8.count <= 128 } } ?? true) && (wifi?.valid ?? true)
    }
}

/// Глобальные DNS/default routers показываются отдельно от выбранного интерфейса:
/// scoped VPN resolver может иметь другую конфигурацию. Не считаем её DNS всех NIC.
public struct NetworkMonitoringSummary: Codable, Equatable, Sendable {
    public let observedInterfaces: Int
    public let omittedInterfaces: Int
    public let configurationCapturedAt: Date?
    public let primaryIPv4: String?
    public let primaryIPv6: String?
    public let routerIPv4: MonitoringMetric<String>
    public let routerIPv6: MonitoringMetric<String>
    public let dnsServers: MonitoringMetric<[String]>
    public init(observedInterfaces: Int, omittedInterfaces: Int = 0, configurationCapturedAt: Date? = nil,
                primaryIPv4: String? = nil, primaryIPv6: String? = nil,
                routerIPv4: MonitoringMetric<String> = .init(), routerIPv6: MonitoringMetric<String> = .init(),
                dnsServers: MonitoringMetric<[String]> = .init()) {
        self.observedInterfaces = observedInterfaces; self.omittedInterfaces = omittedInterfaces
        self.configurationCapturedAt = configurationCapturedAt; self.primaryIPv4 = primaryIPv4; self.primaryIPv6 = primaryIPv6
        self.routerIPv4 = routerIPv4; self.routerIPv6 = routerIPv6; self.dnsServers = dnsServers
    }
    var valid: Bool {
        (0...256).contains(observedInterfaces) && (0...256).contains(omittedInterfaces) &&
        [primaryIPv4, primaryIPv6].allSatisfy { $0.map { $0.utf8.count <= 64 } ?? true } &&
        [routerIPv4.value, routerIPv6.value].allSatisfy { $0.map { $0.utf8.count <= 128 } ?? true } &&
        (dnsServers.value.map { $0.count <= 32 && $0.allSatisfy { $0.utf8.count <= 128 } } ?? true)
    }
}

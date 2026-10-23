import CoreWLAN
import Darwin
import Foundation
import SystemConfiguration

public struct NetworkEnvironment: Sendable {
    public let capturedAt: Date?
    public let configurations: [String: NetworkInterfaceConfiguration]
    public let primaryIPv4: String?
    public let primaryIPv6: String?
    public let routerIPv4: String?
    public let routerIPv6: String?
    public let dnsServers: [String]?
    public init(capturedAt: Date? = nil, configurations: [String: NetworkInterfaceConfiguration] = [:],
                primaryIPv4: String? = nil, primaryIPv6: String? = nil,
                routerIPv4: String? = nil, routerIPv6: String? = nil, dnsServers: [String]? = nil) {
        self.capturedAt = capturedAt; self.configurations = configurations
        self.primaryIPv4 = primaryIPv4; self.primaryIPv6 = primaryIPv6
        self.routerIPv4 = routerIPv4; self.routerIPv6 = routerIPv6; self.dnsServers = dnsServers
    }
}
public protocol NetworkEnvironmentReading: Sendable { func read() -> NetworkEnvironment }

/// Только локальные read-only API. Нет ping/speed test, сканирования Wi-Fi,
/// запроса SSID/BSSID, public-IP lookup или запроса Location Services.
public struct SystemNetworkEnvironmentReader: NetworkEnvironmentReading {
    public init() {}
    public func read() -> NetworkEnvironment {
        let store = SCDynamicStoreCreate(nil, "AthenaNetworkMonitor" as CFString, nil, nil)
        func global(_ entity: CFString) -> [String: Any]? {
            guard let store else { return nil }
            let key = SCDynamicStoreKeyCreateNetworkGlobalEntity(nil, kSCDynamicStoreDomainState, entity)
            return SCDynamicStoreCopyValue(store, key) as? [String: Any]
        }
        let ipv4 = global(kSCEntNetIPv4), ipv6 = global(kSCEntNetIPv6), dns = global(kSCEntNetDNS)
        let addresses = Self.addresses()
        let client = CWWiFiClient.shared()
        var configurations: [String: NetworkInterfaceConfiguration] = [:]
        let wifiNames = client.interfaceNames() ?? []
        for name in Set(addresses?.keys.map { $0 } ?? []).union(wifiNames) {
            var wifi: WiFiMonitoringMetrics?
            if wifiNames.contains(name), let interface = client.interface(withName: name) {
                let powered = interface.powerOn(), rssi = interface.rssiValue(), noise = interface.noiseMeasurement()
                let rate = interface.transmitRate(), channel = interface.wlanChannel().map { $0.channelNumber }
                wifi = WiFiMonitoringMetrics(powered: powered,
                    rssiDBm: powered && (-127 ... -1).contains(rssi) ? rssi : nil,
                    noiseDBm: powered && (-127 ... -1).contains(noise) ? noise : nil,
                    channel: powered ? channel : nil,
                    linkMegabitsPerSecond: powered && rate.isFinite && rate > 0 && rate <= 1_000_000 ? rate : nil)
            }
            configurations[name] = NetworkInterfaceConfiguration(addresses: .init(addresses.map { $0[name] ?? [] }), wifi: wifi)
        }
        return NetworkEnvironment(capturedAt: Date(), configurations: configurations,
            primaryIPv4: ipv4?[kSCDynamicStorePropNetPrimaryInterface as String] as? String,
            primaryIPv6: ipv6?[kSCDynamicStorePropNetPrimaryInterface as String] as? String,
            routerIPv4: ipv4?[kSCPropNetIPv4Router as String] as? String,
            routerIPv6: ipv6?[kSCPropNetIPv6Router as String] as? String,
            dnsServers: dns?[kSCPropNetDNSServerAddresses as String] as? [String])
    }

    private static func addresses() -> [String: [String]]? {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0 else { return nil }
        defer { freeifaddrs(head) }
        var result: [String: [String]] = [:], cursor = head
        while let item = cursor {
            defer { cursor = item.pointee.ifa_next }
            let name = String(cString: item.pointee.ifa_name)
            if result[name] == nil { result[name] = [] }
            guard let address = item.pointee.ifa_addr,
                  address.pointee.sa_family == AF_INET || address.pointee.sa_family == AF_INET6 else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            // NI_NUMERICHOST запрещает reverse DNS: мониторинг не порождает
            // сетевых запросов и сохраняет scope-id link-local IPv6.
            if getnameinfo(address, socklen_t(address.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                result[name, default: []].append(String(cString: host))
            }
        }
        return result.mapValues { Array(Set($0)).sorted() }
    }
}

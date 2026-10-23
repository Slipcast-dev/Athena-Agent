import Darwin
import XCTest
@testable import MacAssistantCore

final class NetworkCollectorTests: XCTestCase {
    func testLiveFactoryProvidesNetworkChannel() async throws {
        let coordinator = MonitoringCoordinator.makeLive()
        _ = try await coordinator.subscribe(groups: [.network])
        await coordinator.waitForCollections()
        let snapshot = await coordinator.snapshot()
        let sample = try XCTUnwrap(snapshot.samples.first { $0.group == .network })
        XCTAssertNotNil(sample.payload, "Live network collector must be registered")
        await coordinator.shutdown()
    }
    private func counter(_ id: String = "en0", rx: UInt64, tx: UInt64 = 0,
                         generation: String = "first", index: UInt32 = 1, up: Bool = true) -> NetworkCounters {
        NetworkCounters(id: id, generation: generation, details: NetworkInterfaceDetails(index: index, up: up,
            running: up, loopback: id == "lo0", pointToPoint: id.hasPrefix("utun"), mtu: 1500,
            receivedBytes: rx, sentBytes: tx, receivedPackets: 5, sentPackets: 3, receivedErrors: 0, sentErrors: 0))
    }
    func test64BitRatesUseActualFractionalElapsedTimeAndMeasuredZero() {
        let before = [counter(rx: 5_000_000_000, tx: 9_000_000_000), counter("utun0", rx: 10)]
        let after = [counter(rx: 5_003_000_000, tx: 9_000_600_000), counter("utun0", rx: 10)]
        let rows = NetworkRateCalculator.calculate(previous: before, current: after, elapsed: 1.5)
        XCTAssertEqual(rows[0].receivedBytesPerSecond.value, 2_000_000)
        XCTAssertEqual(rows[0].sentBytesPerSecond.value, 400_000)
        XCTAssertEqual(rows[1].receivedBytesPerSecond.value, 0)
        XCTAssertEqual(rows[0].details?.receivedBytes, 5_003_000_000)
    }
    func testBaselineResetWrapReconnectAndClockGapNeverInventSpeed() {
        let before = [counter(rx: 100, tx: 100)]
        for after in [[counter(rx: 1, tx: 101)], [counter(rx: 101, tx: 1)],
                      [counter(rx: 101, tx: 101, generation: "second")], [counter(rx: 101, tx: 101, index: 2)]] {
            let rows = NetworkRateCalculator.calculate(previous: before, current: after, elapsed: 1)
            XCTAssertNil(rows[0].receivedBytesPerSecond.value); XCTAssertNil(rows[0].sentBytesPerSecond.value)
            XCTAssertEqual(rows[0].receivedBytesPerSecond.state, .warmingUp)
        }
        for elapsed in [Double?.none, 0, -1, 6, .infinity, .nan, Double.leastNonzeroMagnitude] {
            XCTAssertNil(NetworkRateCalculator.calculate(previous: before, current: [counter(rx: 200, tx: 200)], elapsed: elapsed)[0].receivedBytesPerSecond.value)
        }
    }
    func testNewRemovedAndDisabledInterfacesRemainIndependent() {
        let rows = NetworkRateCalculator.calculate(previous: [counter(rx: 100), counter("utun0", rx: 200)],
            current: [counter(rx: 300), counter("utun1", rx: 500), counter("en1", rx: 600, up: false)], elapsed: 2)
        XCTAssertEqual(rows.map(\.id), ["en0", "utun1", "en1"])
        XCTAssertEqual(rows[0].receivedBytesPerSecond.value, 100)
        XCTAssertEqual(rows[1].receivedBytesPerSecond.state, .warmingUp)
        XCTAssertEqual(rows[2].receivedBytesPerSecond.state, .unavailable)
    }
    func testRouteDecoderPreserves64BitsAtUnalignedRecordBoundary() throws {
        var header = if_msghdr2()
        header.ifm_msglen = UInt16(MemoryLayout<if_msghdr2>.size)
        header.ifm_version = UInt8(RTM_VERSION); header.ifm_type = UInt8(RTM_IFINFO2)
        header.ifm_index = UInt16(if_nametoindex("lo0")); header.ifm_flags = IFF_UP | IFF_RUNNING | IFF_LOOPBACK
        header.ifm_data.ifi_ibytes = 7_000_000_000; header.ifm_data.ifi_obytes = 8_000_000_000
        var prefix: UInt16 = 5
        var data = withUnsafeBytes(of: &prefix) { Data($0) }
        data.append(contentsOf: [UInt8(RTM_VERSION), 0, 0])
        data.append(withUnsafeBytes(of: &header) { Data($0) })
        let rows = try RouteNetworkCounterReader.decode(data)
        XCTAssertEqual(rows.count, 1); XCTAssertEqual(rows[0].id, "lo0")
        XCTAssertEqual(rows[0].details.receivedBytes, 7_000_000_000)
        XCTAssertEqual(rows[0].details.sentBytes, 8_000_000_000); XCTAssertTrue(rows[0].details.loopback)
    }
    func testRouteDecoderRejectsTruncatedInvalidLengthAndVersion() {
        for bytes: [UInt8] in [[1], [0,0,UInt8(RTM_VERSION),UInt8(RTM_IFINFO2)],
                              [255,255,UInt8(RTM_VERSION),UInt8(RTM_IFINFO2)],
                              [4,0,0,UInt8(RTM_IFINFO2)], [4,0,UInt8(RTM_VERSION),UInt8(RTM_IFINFO2)]] {
            XCTAssertThrowsError(try RouteNetworkCounterReader.decode(Data(bytes)))
        }
    }
    func testNativeRouteReaderReturnsRealInterfaceCounters() throws {
        let rows = try RouteNetworkCounterReader().read()
        XCTAssertFalse(rows.isEmpty); XCTAssertLessThanOrEqual(rows.count, 256)
        XCTAssertEqual(Set(rows.map(\.id)).count, rows.count)
        XCTAssertTrue(rows.contains { $0.id == "lo0" && $0.details.loopback })
        for row in rows { XCTAssertGreaterThan(if_nametoindex(row.id), 0) }
    }
    func testCollectorFailureResetsBaselineAndConfigurationCache() async throws {
        let clock = NetworkFixtureClock(), environment = NetworkFixtureEnvironment()
        let reader = NetworkFixtureReader(values: [.success([counter(rx: 100)]), .success([counter(rx: 300)]),
            .failure(NetworkFixtureError.failed), .success([counter(rx: 500)]), .success([counter(rx: 700)])])
        let collector = NetworkMonitoringCollector(reader: reader, clock: clock.clock, environmentReader: environment)
        let first = try await collector.collect(reset: false); XCTAssertEqual(first.state, .warmingUp)
        clock.advance(2)
        let next = try await collector.collect(reset: false)
        guard case .network(let rates, _) = next.payload else { return XCTFail("Missing network") }
        XCTAssertEqual(rates[0].receivedBytesPerSecond.value, 100)
        do { _ = try await collector.collect(reset: false); XCTFail("Failure hidden") } catch {}
        clock.advance(1)
        let restarted = try await collector.collect(reset: false); XCTAssertEqual(restarted.state, .warmingUp)
        clock.advance(1)
        let reset = try await collector.collect(reset: true); XCTAssertEqual(reset.state, .warmingUp)
        XCTAssertEqual(environment.reads, 3)
    }
    func testNetworkAddressesAndWiFiNeverEnterHistory() async throws {
        let clock = NetworkFixtureClock()
        let collector = NetworkMonitoringCollector(reader: NetworkFixtureReader(values: [.success([counter(rx: 100)]), .success([counter(rx: 200)])]),
            clock: clock.clock, environmentReader: NetworkFixtureEnvironment())
        let coordinator = MonitoringCoordinator(collectors: [collector], clock: clock.clock, automaticSampling: false)
        _ = try await coordinator.subscribe(groups: [.network]); await coordinator.waitForCollections()
        clock.advance(1); await coordinator.poll(); await coordinator.waitForCollections()
        let history = try await coordinator.history(.init(group: .network))
        let measured = try XCTUnwrap(history.last)
        XCTAssertEqual(Set(measured.values.keys), ["en0.received", "en0.sent"])
        let text = String(decoding: try JSONEncoder().encode(history), as: UTF8.self)
        XCTAssertFalse(text.contains("192.0.2.")); XCTAssertFalse(text.contains("2001:db8")); XCTAssertFalse(text.contains("rssi"))
        await coordinator.shutdown()
    }
    func testCollectorBoundsInterfacesAndReportsOmissionWithoutLosingPrimary() async throws {
        let rows = (1...40).map { counter("en\($0)", rx: UInt64($0), index: UInt32($0)) }
        let collector = NetworkMonitoringCollector(reader: NetworkFixtureReader(values: [.success(rows)]),
            environmentReader: NetworkFixtureEnvironment(value: .init(primaryIPv4: "en40")))
        let value = try await collector.collect(reset: false)
        guard case .network(let actual, let summary) = value.payload else { return XCTFail("No network") }
        XCTAssertEqual(actual.count, 32); XCTAssertEqual(summary?.observedInterfaces, 40)
        XCTAssertEqual(summary?.omittedInterfaces, 8); XCTAssertEqual(actual.first?.id, "en40")
        XCTAssertTrue(value.payload?.validated() == true)
    }
    func testLegacyNetworkPayloadAndOptionalMetadataValidation() throws {
        let legacy = Data(#"{"network":{"_0":[{"id":"en0","receivedBytesPerSecond":{"state":"available","value":0},"sentBytesPerSecond":{"state":"warmingUp"}}]}}"#.utf8)
        let value = try JSONDecoder().decode(MonitoringPayload.self, from: legacy)
        XCTAssertTrue(value.validated())
        guard case .network(let rows, let summary) = value else { return XCTFail("Wrong payload") }
        XCTAssertNil(summary); XCTAssertNil(rows[0].configuration)
        let invalid = NetworkInterfaceConfiguration(addresses: .init([]), wifi: WiFiMonitoringMetrics(powered: true, rssiDBm: 0))
        XCTAssertFalse(MonitoringPayload.network([.init(id: "en0", receivedBytesPerSecond: .init(1), sentBytesPerSecond: .init(1), configuration: invalid)]).validated())
        XCTAssertFalse(MonitoringPayload.network([], summary: .init(observedInterfaces: 1, omittedInterfaces: .max)).validated())
    }

}

private enum NetworkFixtureError: Error { case failed }
private final class NetworkFixtureReader: NetworkCounterReading, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Result<[NetworkCounters], Error>]
    init(values: [Result<[NetworkCounters], Error>]) { self.values = values }
    func read() throws -> [NetworkCounters] { lock.lock(); defer { lock.unlock() }; return try values.removeFirst().get() }
}
private final class NetworkFixtureClock: @unchecked Sendable {
    private let lock = NSLock()
    private var seconds: Double = 0
    var clock: MonitoringClock { MonitoringClock { self.now() } }
    func now() -> MonitoringInstant {
        lock.lock(); defer { lock.unlock() }
        return MonitoringInstant(monotonic: seconds, date: Date(timeIntervalSince1970: 1_700_000_000 + seconds))
    }
    func advance(_ value: Double) { lock.lock(); seconds += value; lock.unlock() }
}
private final class NetworkFixtureEnvironment: NetworkEnvironmentReading, @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    private let value: NetworkEnvironment?
    init(value: NetworkEnvironment? = nil) { self.value = value }
    var reads: Int { lock.lock(); defer { lock.unlock() }; return count }
    func read() -> NetworkEnvironment {
        lock.lock(); count += 1; lock.unlock()
        if let value { return value }
        return NetworkEnvironment(capturedAt: Date(), configurations: ["en0": .init(addresses: .init(["192.0.2.10", "2001:db8::1"]),
            wifi: .init(powered: true, rssiDBm: -55))], primaryIPv4: "en0", routerIPv4: "192.0.2.1", dnsServers: ["192.0.2.53"])
    }
}

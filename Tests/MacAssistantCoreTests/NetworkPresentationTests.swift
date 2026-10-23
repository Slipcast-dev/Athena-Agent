import XCTest
import EcosystemLocalization
@testable import MacAssistantCore
@testable import MacAssistant

@MainActor
final class NetworkPresentationTests: XCTestCase {
    private func row(_ id: String, up: Bool = true, loopback: Bool = false) -> NetworkInterfaceMetrics {
        NetworkInterfaceMetrics(id: id, receivedBytesPerSecond: .init(100), sentBytesPerSecond: .init(20),
            details: .init(index: 1, up: up, running: up, loopback: loopback, pointToPoint: false, mtu: 1500,
                           receivedBytes: 1000, sentBytes: 200, receivedPackets: 10, sentPackets: 2, receivedErrors: 0, sentErrors: 0))
    }
    private func snapshot(_ rows: [NetworkInterfaceMetrics], primary: String? = nil) -> MonitoringSnapshot {
        MonitoringSnapshot(suspended: false, samples: [.init(group: .network, capturedAt: Date(), intervalSeconds: 1,
            state: .available, payload: .network(rows, summary: .init(observedInterfaces: rows.count, primaryIPv4: primary)), stale: false)])
    }
    func testInitialPrimarySelectionDisappearanceAndPreservingManualChoice() {
        let model = NetworkViewModel(provider: UnavailableLiveMonitoringService())
        model.accept(snapshot: snapshot([row("lo0", loopback: true), row("en0"), row("utun0")], primary: "utun0"), history: [])
        XCTAssertEqual(model.selectedInterface, "utun0")
        model.selectedInterface = "en0"
        model.accept(snapshot: snapshot([row("en0"), row("utun0")], primary: "utun0"), history: [])
        XCTAssertEqual(model.selectedInterface, "en0")
        model.accept(snapshot: snapshot([row("utun0")]), history: [])
        XCTAssertEqual(model.selectedInterface, "utun0")
        model.accept(snapshot: snapshot([]), history: []); XCTAssertEqual(model.selectedInterface, "")
    }
    func testFallbackAvoidsDisabledPrimaryAndLoopbackWhenActiveNICExists() {
        let model = NetworkViewModel(provider: UnavailableLiveMonitoringService())
        model.accept(snapshot: snapshot([row("lo0", loopback: true), row("en0", up: false), row("en1")], primary: "en0"), history: [])
        XCTAssertEqual(model.selectedInterface, "en1")
    }
    func testChartSelectsSingleInterfaceAndDoesNotJoinGaps() {
        let date = Date()
        let history = [MonitoringHistoryPoint(capturedAt: date, state: .available, values: ["en0.received": 100, "en0.sent": 20, "utun0.received": 500]),
            MonitoringHistoryPoint(capturedAt: date.addingTimeInterval(1), state: .available, values: ["utun0.received": 600]),
            MonitoringHistoryPoint(capturedAt: date.addingTimeInterval(2), state: .available, values: ["en0.received": 200, "en0.sent": 0])]
        let points = NetworkChartPoint.make(history, interface: "en0")
        let rx = points.filter(\.received)
        XCTAssertEqual(rx.map(\.bytesPerSecond), [100, 200]); XCTAssertNotEqual(rx[0].segment, rx[1].segment)
        XCTAssertEqual(points.filter { !$0.received }.map(\.bytesPerSecond), [20, 0])
        XCTAssertTrue(NetworkChartPoint.make(history, interface: "en9").isEmpty)
    }
    func testChartRejectsInvalidValuesAndReversedClock() {
        let date = Date()
        let points = NetworkChartPoint.make([
            .init(capturedAt: date, state: .available, values: ["en0.received": 100]),
            .init(capturedAt: date.addingTimeInterval(-1), state: .available, values: ["en0.received": 200]),
            .init(capturedAt: date, state: .available, values: ["en0.received": .nan, "en0.sent": -1])], interface: "en0")
        XCTAssertEqual(points.count, 2); XCTAssertNotEqual(points[0].segment, points[1].segment)
    }
    func testNetworkUnitsUseDecimalScaleSelectedLanguageAndSafeRange() {
        XCTAssertEqual(NetworkFormat.rate(1_000_000, language: .english), "1 MB/s")
        XCTAssertTrue(NetworkFormat.rate(1_000_000, language: .russian).contains("МБ/с"))
        XCTAssertEqual(NetworkFormat.rate(0.5, language: .english), "0.5 B/s")
        XCTAssertEqual(NetworkFormat.rate(0, language: .english), "0 B/s")
        XCTAssertEqual(NetworkFormat.rate(.infinity, language: .english), "—")
        XCTAssertEqual(NetworkFormat.rate(-1, language: .english), "—")
        XCTAssertEqual(NetworkFormat.bytes(1_000_000_000, language: .english), "1 GB")
    }
}

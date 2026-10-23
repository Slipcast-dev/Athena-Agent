import XCTest
import IOKit.ps
@testable import MacAssistantCore

final class BatteryMonitoringTests: XCTestCase {
    private var row: [String: Any] { [kIOPSIsPresentKey: true, kIOPSCurrentCapacityKey: 60,
        kIOPSMaxCapacityKey: 100, kIOPSIsChargingKey: false, kIOPSPowerSourceStateKey: kIOPSBatteryPowerValue] }
    func testDesktopAbsenceDoesNotFabricateZeroCharge() {
        let value = BatteryMonitoringReader.decode(batteries: [])
        XCTAssertEqual(value.present.value, false); XCTAssertNil(value.chargePercent.value); XCTAssertNil(value.details)
    }
    func testMissingPresenceAndMultipleBatteriesAreExplicit() {
        XCTAssertNil(BatteryMonitoringReader.decode(batteries: [[:]]).present.value)
        XCTAssertEqual(BatteryMonitoringReader.decode(batteries: [row, row]).present.state, .unsupported)
        var missing = row; missing[kIOPSIsPresentKey] = false
        XCTAssertNil(BatteryMonitoringReader.decode(batteries: [missing]).chargePercent.value)
    }
    func testCapacityRatioAndElectricalUnits() throws {
        var input = row
        input[kIOPSCurrentCapacityKey] = 3000; input[kIOPSMaxCapacityKey] = 5000
        input[kIOPSDesignCapacityKey] = 6000; input[kIOPSVoltageKey] = 12_500
        input[kIOPSCurrentKey] = -2500; input[kIOPSTemperatureKey] = 32
        let value = BatteryMonitoringReader.decode(batteries: [input], registry: ["CycleCount": 123])
        XCTAssertEqual(value.chargePercent.value, 60)
        XCTAssertEqual(try XCTUnwrap(value.details?.retainedCapacityPercent.value), 83.3333333333, accuracy: 0.0001)
        XCTAssertEqual(value.details?.voltageVolts.value, 12.5)
        XCTAssertEqual(value.details?.currentAmperes.value, -2.5)
        XCTAssertEqual(value.temperatureCelsius.value, 32); XCTAssertEqual(value.cycleCount.value, 123)
    }
    func testIOPSPercentDoesNotMixRegistryMAhOrTemperature() {
        let value = BatteryMonitoringReader.decode(batteries: [row], registry: ["DesignCapacity": 5000,
            "AppleRawMaxCapacity": 4500, "Temperature": 3000])
        XCTAssertNil(value.details?.retainedCapacityPercent.value); XCTAssertNil(value.temperatureCelsius.value)
    }
    func testInvalidNumbersAndBooleanAreRejected() {
        for invalid: Any in [true, -2, 101, Double.nan, Double.infinity, 0.5] {
            var input = row; input[kIOPSCurrentCapacityKey] = invalid
            XCTAssertNil(BatteryMonitoringReader.decode(batteries: [input]).chargePercent.value)
        }
        var input = row; input[kIOPSMaxCapacityKey] = 0; input[kIOPSIsChargingKey] = 1
        XCTAssertNil(BatteryMonitoringReader.decode(batteries: [input]).chargePercent.value)
        XCTAssertNil(BatteryMonitoringReader.decode(batteries: [input]).charging.value)
        XCTAssertNil(BatteryMonitoringReader.number(NSNumber(value: true)))
    }
    func testSignedRegistryCurrentAccepts32And64BitTwosComplement() {
        for value: NSNumber in [NSNumber(value: -1234), NSNumber(value: UInt32(bitPattern: -1234)), NSNumber(value: UInt64(bitPattern: -1234))] {
            XCTAssertEqual(BatteryMonitoringReader.registryCurrent(value), -1234)
        }
        for value: NSNumber in [true, 1.5, 1_000_000, NSNumber(value: UInt64.max / 2)] {
            XCTAssertNil(BatteryMonitoringReader.registryCurrent(value))
        }
    }
    func testTimeEstimatesUseMinutesAndOnlyApplicablePowerState() {
        var input = row; input[kIOPSTimeToEmptyKey] = 120; input[kIOPSTimeToFullChargeKey] = 70
        var value = BatteryMonitoringReader.decode(batteries: [input])
        XCTAssertEqual(value.details?.minutesToEmpty.value, 120); XCTAssertNil(value.details?.minutesToFull.value)
        input[kIOPSIsChargingKey] = true; input[kIOPSPowerSourceStateKey] = kIOPSACPowerValue
        value = BatteryMonitoringReader.decode(batteries: [input])
        XCTAssertNil(value.details?.minutesToEmpty.value); XCTAssertEqual(value.details?.minutesToFull.value, 70)
        input[kIOPSTimeToFullChargeKey] = -1
        XCTAssertEqual(BatteryMonitoringReader.decode(batteries: [input]).details?.minutesToFull.state, .warmingUp)
        input[kIOPSIsChargingKey] = false
        XCTAssertNil(BatteryMonitoringReader.decode(batteries: [input]).details?.minutesToFull.value)
    }
    func testHealthAllowlistAndExternalAdapter() {
        var input = row; input[kIOPSBatteryHealthKey] = kIOPSFairValue
        input[kIOPSBatteryHealthConditionKey] = kIOPSCheckBatteryValue
        input[kIOPSIsChargedKey] = true; input[kIOPSPowerSourceStateKey] = kIOPSACPowerValue
        var value = BatteryMonitoringReader.decode(batteries: [input], adapter: [kIOPSPowerAdapterWattsKey: 67])
        XCTAssertEqual(value.details?.health.value, .fair); XCTAssertEqual(value.details?.condition.value, .checkBattery)
        XCTAssertEqual(value.details?.adapterWatts.value, 67); XCTAssertEqual(value.details?.fullyCharged.value, true)
        input[kIOPSBatteryHealthKey] = "Future value"; input[kIOPSBatteryHealthConditionKey] = "Unknown"
        input[kIOPSPowerSourceStateKey] = kIOPSBatteryPowerValue
        value = BatteryMonitoringReader.decode(batteries: [input], adapter: [kIOPSPowerAdapterWattsKey: 67])
        XCTAssertNil(value.details?.health.value); XCTAssertNil(value.details?.condition.value); XCTAssertNil(value.details?.adapterWatts.value)
    }
    func testPayloadValidationAndNumericHistoryOnly() throws {
        var details = BatteryMonitoringDetails(); details.currentAmperes = .init(-2)
        let value = BatteryMonitoringMetrics(present: .init(true), chargePercent: .init(50), cycleCount: .init(100), details: details)
        XCTAssertTrue(MonitoringPayload.battery(value).validated())
        XCTAssertEqual(MonitoringPayload.battery(value).graphValues, ["charge": 50])
        details.adapterWatts = .init(.infinity)
        XCTAssertFalse(MonitoringPayload.battery(.init(present: .init(true), details: details)).validated())
        XCTAssertFalse(MonitoringPayload.battery(.init(present: .init(true), cycleCount: .init(-1))).validated())
        XCTAssertFalse(MonitoringPayload.battery(.init(present: .init(false), chargePercent: .init(0))).validated())
        let old = BatteryMonitoringMetrics(present: .init(true), chargePercent: .init(80))
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(old)) as? [String: Any])
        json.removeValue(forKey: "details")
        XCTAssertNil(try JSONDecoder().decode(BatteryMonitoringMetrics.self, from: JSONSerialization.data(withJSONObject: json)).details)
    }
    func testCollectorReaderFailureAndCancellationPropagate() async throws {
        let broken = BatteryMonitoringCollector(read: { throw CocoaError(.fileReadUnknown) })
        do { _ = try await broken.collect(reset: false); XCTFail("failure must propagate") } catch { }
        let collector = BatteryMonitoringCollector(read: { .init(present: .init(false)) })
        let result = try await collector.collect(reset: true)
        XCTAssertEqual(result.payload, .battery(.init(present: .init(false))))
        let cancelled = Task { withUnsafeCurrentTask { $0?.cancel() }; return try await collector.collect(reset: false) }
        do { _ = try await cancelled.value; XCTFail("cancelled") } catch is CancellationError { }
    }
    func testNativeReadProducesValidBoundedDTOWithoutHardwareAssumptions() throws {
        XCTAssertTrue(MonitoringPayload.battery(try BatteryMonitoringReader().read()).validated())
    }
    func testLiveFactoryConnectsBatteryAndAbsentHasNoGraphValue() async throws {
        let coordinator = MonitoringCoordinator.makeLive()
        let lease = try await coordinator.subscribe(groups: [.battery])
        await coordinator.waitForCollections()
        let snapshot = await coordinator.snapshot()
        let sample = try XCTUnwrap(snapshot.samples.first { $0.group == .battery })
        XCTAssertEqual(sample.state, .available); XCTAssertFalse(sample.stale)
        guard case .battery = sample.payload else { XCTFail("Live battery collector missing"); return }
        await coordinator.unsubscribe(lease.id)
        await coordinator.shutdown()
        XCTAssertTrue(MonitoringPayload.battery(.init(present: .init(false))).graphValues.isEmpty)
    }

}

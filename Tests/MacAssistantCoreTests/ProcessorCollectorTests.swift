import Darwin
import XCTest
@testable import MacAssistantCore

/// Счётчики задаются независимо от вычислителя; ожидаемые проценты ниже
/// следуют из явных интервалов 100/200 ticks, а не повторения реализации.
final class ProcessorCollectorTests: XCTestCase {
    private func ticks(_ user: UInt32, _ system: UInt32, _ idle: UInt32, _ nice: UInt32 = 0) -> ProcessorTicks {
        ProcessorTicks(user: user, system: system, idle: idle, nice: nice)
    }

    func testPerCorePercentAndWeightedTotalNormalizeTo100() throws {
        let before = [ticks(100, 100, 100), ticks(100, 100, 100)]
        let after = [ticks(120, 110, 170), ticks(160, 140, 200)]
        let actual = try XCTUnwrap(ProcessorLoadCalculator.calculate(previous: before, current: after))
        XCTAssertEqual(actual.cores.map(\.value), [30, 50])
        XCTAssertEqual(try XCTUnwrap(actual.totalPercent.value), 130.0 / 300 * 100, accuracy: 1e-10)
        XCTAssertEqual(try XCTUnwrap(actual.userPercent.value), 80.0 / 300 * 100, accuracy: 1e-10)
        XCTAssertEqual(try XCTUnwrap(actual.systemPercent.value), 50.0 / 300 * 100, accuracy: 1e-10)
    }

    func testNiceCountsAsUserAndIdleCoreIsMeasuredZero() throws {
        let actual = try XCTUnwrap(ProcessorLoadCalculator.calculate(
            previous: [ticks(0, 0, 0), ticks(0, 0, 0)], current: [ticks(10, 10, 70, 10), ticks(0, 0, 100)]))
        XCTAssertEqual(actual.cores.map(\.value), [30, 0])
        XCTAssertEqual(actual.userPercent.value, 10)
        XCTAssertEqual(actual.systemPercent.value, 5)
        XCTAssertEqual(actual.totalPercent.value, 15)
    }

    func testResetWrapTopologyAndNoElapsedTicksDoNotInventLoad() {
        XCTAssertNil(ProcessorLoadCalculator.calculate(previous: [ticks(100, 0, 0)], current: [ticks(1, 1, 1)]))
        XCTAssertNil(ProcessorLoadCalculator.calculate(previous: [ticks(.max, 0, 0)], current: [ticks(0, 1, 0)]))
        XCTAssertNil(ProcessorLoadCalculator.calculate(previous: [], current: []))
        XCTAssertNil(ProcessorLoadCalculator.calculate(previous: [ticks(1, 1, 1)], current: []))
        XCTAssertNil(ProcessorLoadCalculator.calculate(previous: [ticks(1, 1, 1)], current: [ticks(1, 1, 1)]))
    }

    func testUnchangedSingleCoreIsUnavailableWhileOtherCoreHasTicks() throws {
        let actual = try XCTUnwrap(ProcessorLoadCalculator.calculate(previous: [ticks(0, 0, 0), ticks(1, 1, 1)],
            current: [ticks(50, 0, 50), ticks(1, 1, 1)]))
        XCTAssertEqual(actual.totalPercent.value, 50)
        XCTAssertNil(actual.cores[1].value); XCTAssertEqual(actual.cores[1].state, .warmingUp)
    }

    func testCollectorFirstSampleResetAndFailureRequireNewBaseline() async throws {
        let reader = ProcessorFixtureReader(samples: [
            .success([ticks(0, 0, 0)]), .success([ticks(50, 0, 50)]),
            .failure(ProcessorFixtureError.failed), .success([ticks(100, 0, 100)]),
            .success([ticks(150, 0, 150)]), .success([ticks(200, 0, 200)])])
        let collector = ProcessorMonitoringCollector(reader: reader)
        let first = try await collector.collect(reset: false)
        XCTAssertEqual(first.state, .warmingUp)
        let measured = try await collector.collect(reset: false)
        XCTAssertEqual(measured.state, .available)
        do { _ = try await collector.collect(reset: false); XCTFail("Read failure hidden") } catch {}
        let afterError = try await collector.collect(reset: false)
        XCTAssertEqual(afterError.state, .warmingUp)
        let next = try await collector.collect(reset: false); XCTAssertEqual(next.state, .available)
        let reset = try await collector.collect(reset: true); XCTAssertEqual(reset.state, .warmingUp)
    }

    func testPerCoreAggregateAgreesWithIndependentHostCPUCounter() async throws {
        let reader = MachProcessorCounterReader()
        let before = try reader.read(), hostBefore = try hostCPU()
        try await Task.sleep(for: .milliseconds(1200))
        let after = try reader.read(), hostAfter = try hostCPU()
        let actual = try XCTUnwrap(ProcessorLoadCalculator.calculate(previous: before, current: after)?.totalPercent.value)
        let expected = try XCTUnwrap(CPUUsageCalculator.usagePercent(previous: hostBefore, current: hostAfter))
        // Разные syscalls не атомарны. Допуск 3 percentage points учитывает
        // округление aggregate ticks и небольшой сдвиг момента выборки.
        XCTAssertLessThanOrEqual(abs(actual - expected), 3)
        if let path = ProcessInfo.processInfo.environment["ATHENA_CPU_COMPARISON_OUTPUT"] {
            let data = try JSONSerialization.data(withJSONObject: [
                "logicalCores": after.count, "perCoreAggregatePercent": actual,
                "independentHostPercent": expected, "absoluteDifferencePercentagePoints": abs(actual - expected),
                "maximumAllowedDifferencePercentagePoints": 3, "status": "passed"
            ], options: [.sortedKeys, .prettyPrinted])
            try data.write(to: URL(fileURLWithPath: path))
        }
    }

    private func hostCPU() throws -> CPUTimeSnapshot {
        let host = mach_host_self(); defer { mach_port_deallocate(mach_task_self_, host) }
        var value = host_cpu_load_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info_data_t>.size / MemoryLayout<integer_t>.size)
        let code = withUnsafeMutablePointer(to: &value) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(host, HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard code == KERN_SUCCESS else { throw ProcessorFixtureError.failed }
        return CPUTimeSnapshot(user: UInt64(value.cpu_ticks.0), system: UInt64(value.cpu_ticks.1),
                               idle: UInt64(value.cpu_ticks.2), nice: UInt64(value.cpu_ticks.3))
    }

    func testNativeCollectorHasOneFieldPerLogicalCPUAndReleasesHostRights() async throws {
        let host = mach_host_self(); defer { mach_port_deallocate(mach_task_self_, host) }
        let reader = MachProcessorCounterReader()
        _ = try reader.read() // прогреваем системные функции до сравнения refs
        var before: mach_port_urefs_t = 0, after: mach_port_urefs_t = 0
        XCTAssertEqual(mach_port_get_refs(mach_task_self_, host, mach_port_right_t(MACH_PORT_RIGHT_SEND), &before), KERN_SUCCESS)
        for _ in 0..<30 {
            let values = try reader.read()
            XCTAssertGreaterThan(values.count, 0); XCTAssertLessThanOrEqual(values.count, 256)
        }
        XCTAssertEqual(mach_port_get_refs(mach_task_self_, host, mach_port_right_t(MACH_PORT_RIGHT_SEND), &after), KERN_SUCCESS)
        XCTAssertEqual(after, before)
        let collector = ProcessorMonitoringCollector()
        let sample = try await collector.collect(reset: true)
        guard case .cpu(let data) = sample.payload else { return XCTFail("CPU payload absent") }
        XCTAssertEqual(data.cores.count, try reader.read().count)
        XCTAssertEqual(data.identity?.logicalCoreCount, data.cores.count)
    }
}

private enum ProcessorFixtureError: Error { case failed }
private final class ProcessorFixtureReader: ProcessorCounterReading, @unchecked Sendable {
    private let lock = NSLock()
    private var samples: [Result<[ProcessorTicks], Error>]
    init(samples: [Result<[ProcessorTicks], Error>]) { self.samples = samples }
    func read() throws -> [ProcessorTicks] {
        lock.lock(); defer { lock.unlock() }
        return try samples.removeFirst().get()
    }
}

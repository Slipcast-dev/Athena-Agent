import Darwin
import Dispatch
import XCTest
@testable import MacAssistantCore

private struct MemoryFixtureReader: MemoryCounterReading {
    let value: MemoryCounters
    func read() throws -> MemoryCounters { value }
}
private struct ProcessFixtureReader: ProcessMemoryReadingProviding {
    let value: ProcessMemoryReading
    func read() throws -> ProcessMemoryReading { value }
}

final class MemoryCollectorTests: XCTestCase {
    private func counters(total: UInt64 = 1000, page: UInt64 = 10,
                          free: UInt64 = 10, inactive: UInt64 = 20,
                          swap: UInt64? = 0, pressure: MemoryPressure? = .warning) -> MemoryCounters {
        MemoryCounters(total: total, pageSize: page, free: free, inactive: inactive,
                       wired: 15, compressed: 5, fileBacked: 30, swapUsed: swap, pressure: pressure)
    }
    func testCategoriesDoNotDoubleCountFileBackedOrCompressed() throws {
        let value = try MemoryMetricsCalculator.calculate(counters())
        XCTAssertEqual(value.totalBytes.value, 1000)
        XCTAssertEqual(value.usedBytes.value, 700); XCTAssertEqual(value.availableBytes.value, 300)
        XCTAssertEqual(value.wiredBytes.value, 150); XCTAssertEqual(value.compressedBytes.value, 50)
        XCTAssertEqual(value.cachedBytes.value, 300); XCTAssertEqual(value.swapUsedBytes.value, 0)
        XCTAssertEqual(value.pressure.value, .warning)
    }
    func testUnknownSwapPressureStayUnavailableAndRAMMayBeFullyUsed() throws {
        let value = try MemoryMetricsCalculator.calculate(counters(free: 0, inactive: 0, swap: nil, pressure: nil))
        XCTAssertEqual(value.usedBytes.value, 1000); XCTAssertEqual(value.availableBytes.value, 0)
        XCTAssertNil(value.swapUsedBytes.value); XCTAssertNil(value.pressure.value)
        XCTAssertEqual(value.pressure.state, .unavailable)
    }
    func testOverflowImpossibleCountsAndZeroPageSizeFailClosed() {
        for value in [counters(total: 0), counters(page: 0), counters(page: .max),
                      counters(free: 101), counters(free: 80, inactive: 30)] {
            XCTAssertThrowsError(try MemoryMetricsCalculator.calculate(value))
        }
    }
    func testPressureSysctlUsesDispatchFlagsNotInternalKernelEnum() {
        XCTAssertEqual(MachMemoryCounterReader.decodePressure(UInt32(DispatchSource.MemoryPressureEvent.normal.rawValue)), .normal)
        XCTAssertEqual(MachMemoryCounterReader.decodePressure(UInt32(DispatchSource.MemoryPressureEvent.warning.rawValue)), .warning)
        XCTAssertEqual(MachMemoryCounterReader.decodePressure(UInt32(DispatchSource.MemoryPressureEvent.critical.rawValue)), .critical)
        for unknown: UInt32 in [0, 3, 7, .max] { XCTAssertNil(MachMemoryCounterReader.decodePressure(unknown)) }
    }
    func testCollectorDoesNotRequireDifferentialWarmup() async throws {
        let collector = MemoryMonitoringCollector(reader: MemoryFixtureReader(value: counters()))
        for reset in [false, true] {
            let value = try await collector.collect(reset: reset)
            XCTAssertEqual(value.state, .available)
            guard case .memory(let metrics) = value.payload else { return XCTFail("Memory missing") }
            XCTAssertEqual(metrics.usedBytes.value, 700)
        }
    }
    func testNativeMemorySnapshotReleasesMachRights() throws {
        let reader = MachMemoryCounterReader()
        let host = mach_host_self(); defer { mach_port_deallocate(mach_task_self_, host) }
        _ = try reader.read()
        var before: mach_port_urefs_t = 0, after: mach_port_urefs_t = 0
        XCTAssertEqual(mach_port_get_refs(mach_task_self_, host, mach_port_right_t(MACH_PORT_RIGHT_SEND), &before), KERN_SUCCESS)
        for _ in 0..<30 {
            let metrics = try MemoryMetricsCalculator.calculate(reader.read())
            XCTAssertEqual(metrics.totalBytes.value, ProcessInfo.processInfo.physicalMemory)
            XCTAssertEqual((metrics.usedBytes.value ?? 0) + (metrics.availableBytes.value ?? 0), ProcessInfo.processInfo.physicalMemory)
            XCTAssertNotNil(metrics.compressedBytes.value)
        }
        XCTAssertEqual(mach_port_get_refs(mach_task_self_, host, mach_port_right_t(MACH_PORT_RIGHT_SEND), &after), KERN_SUCCESS)
        XCTAssertEqual(before, after)
    }
    func testProcessEnumerationExposesMissingAndOmittedCounts() async throws {
        let rows = (1...600).map { ProcessMemoryMetrics(pid: Int32($0), name: "Process", footprintBytes: $0 == 1 ? .init() : .init(UInt64($0))) }
        let source = ProcessMemoryCollector(reader: ProcessFixtureReader(value: ProcessMemoryReading(rows: rows, enumerationComplete: false)))
        let result = try await source.collect(reset: true)
        guard case .processes(let actual, let summary) = result.payload else { return XCTFail("Processes missing") }
        XCTAssertEqual(actual.count, 512); XCTAssertEqual(actual.first?.pid, 600)
        XCTAssertEqual(summary?.observed, 600); XCTAssertEqual(summary?.readable, 599)
        XCTAssertEqual(summary?.unavailable, 1); XCTAssertEqual(summary?.omitted, 88)
        XCTAssertEqual(summary?.enumerationComplete, false); XCTAssertTrue(result.payload?.validated() == true)
    }
    func testNativeLibprocReadsOwnFootprintWithoutExportingExecutablePath() throws {
        let actual = try LibprocMemoryReader().read()
        let own = try XCTUnwrap(actual.rows.first { $0.pid == getpid() })
        XCTAssertGreaterThan(try XCTUnwrap(own.footprintBytes.value), 0)
        let json = try JSONEncoder().encode(own)
        XCTAssertFalse(String(decoding: json, as: UTF8.self).contains("/Users/"))
    }
    func testBundleHelpersGroupOnlyUnderConfirmedOuterApplication() throws {
        let helper = try XCTUnwrap(LibprocMemoryReader.application(executablePath: "/Applications/Example.app/Contents/Frameworks/Helper.app/Contents/MacOS/helper"))
        let main = try XCTUnwrap(LibprocMemoryReader.application(executablePath: "/Applications/Example.app/Contents/MacOS/main"))
        let other = try XCTUnwrap(LibprocMemoryReader.application(executablePath: "/Other/Example.app/Contents/MacOS/main"))
        XCTAssertEqual(helper.id, main.id); XCTAssertEqual(main.name, "Example")
        XCTAssertNotEqual(main.id, other.id); XCTAssertFalse(main.id.contains("/"))
        XCTAssertNil(LibprocMemoryReader.application(executablePath: "/usr/libexec/daemon"))
        XCTAssertNil(LibprocMemoryReader.application(executablePath: "/Apps/../Example.app/bin/main"))
    }
    func testLegacyProcessPayloadDecodesWithMissingOptionalMetadata() throws {
        let data = Data(#"{"processes":{"_0":[{"pid":1,"name":"Legacy","footprintBytes":{"state":"available","value":100}}]}}"#.utf8)
        let value = try JSONDecoder().decode(MonitoringPayload.self, from: data)
        guard case .processes(let rows, let summary) = value else { return XCTFail("Wrong payload") }
        XCTAssertNil(summary); XCTAssertNil(rows.first?.applicationID)
        XCTAssertEqual(rows.first?.footprintBytes.value, 100); XCTAssertTrue(value.validated())
    }
    func testProcessPayloadRejectsDuplicateIDsAndInconsistentCoverage() {
        let row = ProcessMemoryMetrics(pid: 1, name: "Example", footprintBytes: .init(1))
        XCTAssertFalse(MonitoringPayload.processes([row, row]).validated())
        XCTAssertFalse(MonitoringPayload.processes([row], summary: .init(observed: 1, readable: 1, unavailable: 0, omitted: .max, enumerationComplete: true)).validated())
        XCTAssertFalse(MonitoringPayload.processes([row], summary: .init(observed: 1, readable: 2, unavailable: 0, omitted: 0, enumerationComplete: true)).validated())
        XCTAssertFalse(MonitoringPayload.processes([ProcessMemoryMetrics(pid: 1, name: "Example", footprintBytes: .init(1), applicationID: "unsafe/path", applicationName: "Example")]).validated())
    }
}

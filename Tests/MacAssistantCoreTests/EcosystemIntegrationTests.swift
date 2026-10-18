import XCTest
@testable import MacAssistantCore

final class EcosystemIntegrationTests: XCTestCase {
    func testMCPUsesSharedContractWithoutClaimingRuntimeIntegration() {
        let info = AthenaEcosystem.descriptor.experimentalCapability
        XCTAssertEqual(info["agentId"] as? String, "athena")
        XCTAssertEqual(info["major"] as? Int, 1)
        XCTAssertEqual(info["minor"] as? Int, 0)
        XCTAssertEqual(info["runtimeIntegrated"] as? Bool, false)
    }
}

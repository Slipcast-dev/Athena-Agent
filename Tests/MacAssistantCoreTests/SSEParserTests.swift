import XCTest
@testable import MacAssistantCore

final class SSEParserTests: XCTestCase {
    func testParserHandlesFragmentedFramesAndDoneMarker() {
        var parser = SSEParser()
        XCTAssertEqual(parser.append(Data("data: {\"a\":1}".utf8)), [])
        XCTAssertEqual(parser.append(Data("\n\ndata: [DONE]\n\n".utf8)), ["{\"a\":1}"])
    }
}

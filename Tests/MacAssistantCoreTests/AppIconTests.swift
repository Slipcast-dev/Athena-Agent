import AppKit
import XCTest

final class AppIconTests: XCTestCase {
    func testIconHasTransparentExteriorAndOpaqueArtwork() throws {
        // Проверяем ресурс независимо от упаковщика: непрозрачные углы PNG
        // превращаются в заметный квадрат в Dock независимо от Info.plist.
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let data = try Data(contentsOf: root.appendingPathComponent(
            "Sources/MacAssistant/Resources/AgentAthena.png"))
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: data))
        XCTAssertEqual(bitmap.pixelsWide, bitmap.pixelsHigh)
        XCTAssertTrue(bitmap.hasAlpha)
        for x in [0, bitmap.pixelsWide - 1] {
            for y in [0, bitmap.pixelsHigh - 1] {
                let color = try XCTUnwrap(bitmap.colorAt(x: x, y: y))
                XCTAssertLessThan(color.alphaComponent, 0.01, "Внешний угол должен быть прозрачным")
            }
        }
        let center = try XCTUnwrap(bitmap.colorAt(
            x: bitmap.pixelsWide / 2, y: bitmap.pixelsHigh / 2))
        XCTAssertGreaterThan(center.alphaComponent, 0.99, "Сама Афина должна оставаться непрозрачной")
    }
}

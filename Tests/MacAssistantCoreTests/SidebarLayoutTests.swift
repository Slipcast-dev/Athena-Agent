import AppKit
import SwiftUI
import XCTest
@testable import MacAssistant

@MainActor
final class SidebarLayoutTests: XCTestCase {
    func testReferenceScaleAndSymbols() throws {
        // Образец Retina приблизительно соответствует тексту 16 pt и значкам
        // 20 pt. Эти ожидания задаёт визуальное ТЗ, а не алгоритм отрисовки.
        XCTAssertEqual(SidebarStyle.labelSize, 16)
        XCTAssertEqual(SidebarStyle.iconSize, 20)
        XCTAssertEqual(SidebarStyle.titleSize, 12)
        XCTAssertGreaterThanOrEqual(SidebarStyle.rowHeight, SidebarStyle.iconSize + 12)
        XCTAssertEqual(AppSection.dashboard.systemImage, "square.grid.2x2")
        for section in AppSection.allCases {
            XCTAssertNotNil(NSImage(systemSymbolName: section.systemImage, accessibilityDescription: nil))
        }
        // Независимая формула относительной яркости WCAG для белого крупного
        // жирного текста на фактически заданном sRGB-акценте.
        let color = try XCTUnwrap(NSColor(SidebarStyle.accent).usingColorSpace(.sRGB))
        let components = [color.redComponent, color.greenComponent, color.blueComponent].map {
            $0 <= 0.04045 ? $0 / 12.92 : pow(($0 + 0.055) / 1.055, 2.4)
        }
        let luminance = components[0] * 0.2126 + components[1] * 0.7152 + components[2] * 0.0722
        XCTAssertGreaterThanOrEqual(1.05 / (luminance + 0.05), 3)
    }

    func testArrowNavigationPreservesSectionsAndBoundaries() {
        XCTAssertEqual(SidebarView.destination(from: .dashboard, direction: .down), .diagnostics)
        XCTAssertEqual(SidebarView.destination(from: .settings, direction: .up), .storage)
        XCTAssertEqual(SidebarView.destination(from: .dashboard, direction: .up), .dashboard)
        XCTAssertEqual(SidebarView.destination(from: .settings, direction: .down), .settings)
        XCTAssertNil(SidebarView.destination(from: .dashboard, direction: .left))
    }

    func testSidebarRendersEverySelectionInBothThemes() async throws {
        let output = ProcessInfo.processInfo.environment["MACASSISTANT_UI_SNAPSHOTS_DIR"]
        for section in AppSection.allCases {
            for theme in [ColorScheme.light, .dark] {
                for width in [SidebarStyle.minimumWidth, SidebarStyle.maximumWidth] {
                    let root = SidebarView(selection: .constant(section))
                        .environment(\.colorScheme, theme)
                        .environment(\.controlActiveState, .active)
                        .frame(width: width, height: 400)
                    let host = NSHostingView(rootView: root)
                    host.frame = NSRect(x: 0, y: 0, width: width, height: 400)
                    // Native List создаёт строки лениво после включения в окно.
                    // Без этого тест мог бы сохранить пустую, но валидную PNG.
                    let window = NSWindow(contentRect: host.bounds, styleMask: [.titled],
                                          backing: .buffered, defer: false)
                    window.isReleasedWhenClosed = false
                    window.contentView = host
                    defer { window.close() }
                    try await Task.sleep(for: .milliseconds(60))
                    host.layoutSubtreeIfNeeded()
                    let table = try XCTUnwrap(descendants(of: host).compactMap { $0 as? NSTableView }.first)
                    XCTAssertGreaterThanOrEqual(table.numberOfRows, AppSection.allCases.count)
                    let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                    host.cacheDisplay(in: host.bounds, to: bitmap)
                    XCTAssertGreaterThanOrEqual(bitmap.pixelsWide, Int(width))
                    // Размер PNG сам по себе не доказывает видимость меню.
                    // Проверяем заметную площадь синего выделения: одних тонких
                    // значков недостаточно, чтобы пройти этот порог.
                    var blueSamples = 0
                    var sampleCount = 0
                    for y in stride(from: 0, to: bitmap.pixelsHigh, by: 8) {
                        for x in stride(from: 0, to: bitmap.pixelsWide, by: 8) {
                            sampleCount += 1
                            // ColorSync меняет абсолютные компоненты системного
                            // синего между профилями. Проверяем преобладание
                            // синего, а не конкретный hex в цветовом профиле Mac.
                            if let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB),
                               color.blueComponent > 0.7,
                               color.blueComponent - color.redComponent > 0.4,
                               color.blueComponent - color.greenComponent > 0.2,
                               color.greenComponent > 0.15 {
                                blueSamples += 1
                            }
                        }
                    }
                    XCTAssertGreaterThan(Double(blueSamples) / Double(sampleCount), 0.03)
                    if let output {
                        let directory = URL(fileURLWithPath: output, isDirectory: true)
                        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                        let name = "sidebar-\(section.rawValue)-\(theme == .light ? "light" : "dark")-\(Int(width)).png"
                        try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                            .write(to: directory.appendingPathComponent(name))
                    }
                }
            }
        }
    }

    private func descendants(of view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap { descendants(of: $0) }
    }
}

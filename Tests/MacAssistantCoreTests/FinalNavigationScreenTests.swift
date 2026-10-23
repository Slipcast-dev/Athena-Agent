import AppKit
import SwiftUI
import XCTest
import EcosystemLocalization
@testable import MacAssistant

@MainActor
final class FinalNavigationScreenTests: XCTestCase {
    func testSevenSectionMenuRendersInBothLanguagesThemesAndWidths() async throws {
        for language in AgentLanguage.allCases {
            for theme in [ColorScheme.light, .dark] {
                for width in [SidebarStyle.minimumWidth, SidebarStyle.maximumWidth] {
                    let host = NSHostingView(rootView: SidebarView(selection: .constant(.disk))
                        .environment(\.agentLanguage, language).environment(\.colorScheme, theme)
                        .environment(\.controlActiveState, .active).frame(width: width, height: 520))
                    host.frame = NSRect(x: 0, y: 0, width: width, height: 520)
                    let window = NSWindow(contentRect: host.bounds, styleMask: [.titled], backing: .buffered, defer: false)
                    window.isReleasedWhenClosed = false; window.contentView = host
                    window.appearance = NSAppearance(named: theme == .light ? .aqua : .darkAqua)
                    host.appearance = window.appearance
                    window.orderFrontRegardless(); window.displayIfNeeded()
                    defer { window.close() }
                    try await Task.sleep(for: .milliseconds(150))
                    host.layoutSubtreeIfNeeded()
                    let table = try XCTUnwrap(descendants(host).compactMap { $0 as? NSTableView }.first)
                    // NSTableView включает заголовок Section «Athena» отдельной
                    // строкой: одна шапка плюс ровно семь конечных разделов.
                    XCTAssertEqual(table.numberOfRows, 8, "One Athena header and exactly seven destination rows")
                    let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                    window.appearance?.performAsCurrentDrawingAppearance { host.cacheDisplay(in: host.bounds, to: bitmap) }
                    XCTAssertGreaterThanOrEqual(bitmap.pixelsWide, Int(width))
                    if let path = ProcessInfo.processInfo.environment["ATHENA_FINAL_SCREENSHOTS_DIR"] {
                        let directory = URL(fileURLWithPath: path)
                        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to:
                            directory.appendingPathComponent("menu-\(language.rawValue)-\(theme == .light ? "light" : "dark")-\(Int(width)).png"))
                    }
                }
            }
        }
    }
    private func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
}

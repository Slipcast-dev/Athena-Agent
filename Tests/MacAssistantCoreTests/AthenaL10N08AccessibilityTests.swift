import AppKit
import SwiftUI
import XCTest
import EcosystemLocalization
import MacAssistantCore
@testable import MacAssistant

/// Это проверки раскрытого нативного AX-дерева в изолированном окне, не ручная
/// приёмка VoiceOver и не UI scripting рабочего приложения. Кнопки не нажимаются.
@MainActor final class AthenaL10N08AccessibilityTests: XCTestCase {
    private func elements(_ root: Any) -> [any NSAccessibilityProtocol] {
        var result: [any NSAccessibilityProtocol] = []
        var pending: [Any] = [root]
        var visited = Set<ObjectIdentifier>()
        while let current = pending.popLast(), visited.count < 4096 {
            guard let node = current as? any NSAccessibilityProtocol else { continue }
            guard visited.insert(ObjectIdentifier(node as AnyObject)).inserted else { continue }
            result.append(node)
            pending.append(contentsOf: node.accessibilityChildren() ?? [])
        }
        return result
    }
    private func check<V: View>(_ view: V, width: CGFloat, height: CGFloat,
                                language: AgentLanguage, buttonTitles: [String], fieldLabel: String? = nil) async throws {
        // Интерактивный режим существует только в XCTest: GUI/runtime bootstrap
        // не вызывается. Показываем один язык, не затрагивая личные defaults.
        let previewLanguage = ProcessInfo.processInfo.environment["ECOSYSTEM_L10N_PREVIEW_LANGUAGE"]
        if let previewLanguage, previewLanguage != language.rawValue { return }
        let host = NSHostingView(rootView: view.environment(\.agentLanguage, language)
            .frame(width: width, height: height))
        host.frame = NSRect(x: 0, y: 0, width: width, height: height)
        let window = NSWindow(contentRect: host.bounds, styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host
        defer { window.close() }
        // Реально показанное собственное окно позволяет AppKit создать AX bridge.
        // Нет AX-запросов к другим приложениям, TCC или системным настройкам.
        window.title = "Athena — L10N test — " + language.rawValue
        window.center()
        if previewLanguage != nil {
            // XCTest не является обычным GUI bundle: активируем только свой
            // процесс, иначе показанное окно может остаться за Codex.
            NSApplication.shared.setActivationPolicy(.regular)
            window.collectionBehavior = [.moveToActiveSpace]
            NSApplication.shared.activate(ignoringOtherApps: true)
        }
        window.makeKeyAndOrderFront(nil)
        if previewLanguage != nil { window.orderFrontRegardless() }
        try await Task.sleep(for: .milliseconds(350))
        if previewLanguage != nil {
            // Ждём закрытия собственного окна либо две минуты. Состояние только
            // синтетическое; мониторинг/сохранение/доступ к файлам не запускаются.
            let deadline = Date().addingTimeInterval(120)
            while window.isVisible && Date() < deadline {
                try await Task.sleep(for: .milliseconds(250))
            }
        }
        host.layoutSubtreeIfNeeded()
        // Обходим содержимое: кнопка закрытия рамки не доказывает доступность SwiftUI.
        let nodes = elements(host)
        let buttons = nodes.filter { $0.accessibilityRole() == .button }
        // SwiftUI AX bridge зависит от ОС. Отсутствие всего дерева
        // является явно skipped проверкой, а не доказательством доступности.
        guard !buttons.isEmpty else { throw XCTSkip("Native SwiftUI AX buttons unavailable in visible test window; manual acceptance required") }
        let bounds = window.convertToScreen(host.convert(host.bounds, to: nil)).insetBy(dx: -2, dy: -2)
        for title in buttonTitles {
            let button = try XCTUnwrap(buttons.first { ($0.accessibilityLabel() ?? $0.accessibilityTitle()) == title },
                                       "Missing localized AX button: " + title)
            let frame = button.accessibilityFrame()
            XCTAssertGreaterThan(frame.width, 0)
            XCTAssertGreaterThan(frame.height, 0)
            XCTAssertTrue(bounds.contains(frame), "Button outside content bounds: " + title)
            // Native control needs enough width for the full localized caption;
            // a bitmap with many colors alone cannot catch an ellipsis here.
            let textWidth = (title as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: NSFont.systemFontSize)]).width
            XCTAssertGreaterThanOrEqual(frame.width + 2, textWidth, "Potential truncated caption: " + title)
        }
        if let fieldLabel {
            XCTAssertTrue(nodes.contains { $0.accessibilityRole() == .textField && $0.accessibilityLabel() == fieldLabel },
                          "Persistent text field label missing: " + fieldLabel)
        }
    }
    func testMonitorApprovalButtonsFitWithLongNameAndLocalizedAXTitles() async throws {
        var rule = MonitorRule()
        rule.name = String(repeating: "LongName ", count: 12)
        for language in AgentLanguage.allCases {
            let l10n = AthenaLocalization(language: language)
            try await check(MonitorReviewContent(rule: rule, expiresAt: Date().addingTimeInterval(300),
                error: nil, l10n: l10n).padding(24), width: 500, height: 650, language: language,
                buttonTitles: [l10n.text("Отмена"), l10n.text("Подтвердить мониторинг")])
        }
    }
}

import AppKit
import SwiftUI

/// Узкий AppKit bridge нужен для occlusion/minimize конкретного окна.
/// ScenePhase отдельно останавливает опрос, когда приложение уходит в фон.
struct DashboardWindowVisibility: NSViewRepresentable {
    let changed: (Bool) -> Void
    func makeNSView(context: Context) -> VisibilityView { VisibilityView(changed: changed) }
    func updateNSView(_ view: VisibilityView, context: Context) { view.changed = changed }
    final class VisibilityView: NSView {
        var changed: (Bool) -> Void
        private var observers: [NSObjectProtocol] = []
        private var last: Bool?
        init(changed: @escaping (Bool) -> Void) { self.changed = changed; super.init(frame: .zero) }
        required init?(coder: NSCoder) { nil }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            observers.forEach(NotificationCenter.default.removeObserver); observers.removeAll()
            if let window {
                for name in [NSWindow.didChangeOcclusionStateNotification, NSWindow.didMiniaturizeNotification, NSWindow.didDeminiaturizeNotification] {
                    observers.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                        Task { @MainActor [weak self] in self?.report() }
                    })
                }
            }
            // State SwiftUI меняется после фазы создания NSView, не в render.
            Task { @MainActor [weak self] in self?.report() }
        }
        private func report() {
            let visible = window.map { $0.isVisible && !$0.isMiniaturized && $0.occlusionState.contains(.visible) } ?? false
            guard last != visible else { return }; last = visible; changed(visible)
        }
        deinit { observers.forEach(NotificationCenter.default.removeObserver) }
    }
}

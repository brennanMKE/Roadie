import AppKit
import Observation
import SwiftUI

/// Owns the player model and the skinned windows. They are AppKit `NSWindow`s, not SwiftUI scenes, because a borderless
/// window needs a subclass (`SkinWindow`). One `SkinWindowController` per window, told apart by its `SkinWindowKind`.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = PlayerModel()
    private(set) lazy var player = SkinWindowController(kind: .main, model: model, rootView: PlayerView())
    private(set) lazy var equalizer: SkinWindowController = {
        let controller = SkinWindowController(kind: .equalizer, model: model, rootView: EqualizerView())
        controller.onClose = { [model] in model.setEQWindowOpen(false) }
        return controller
    }()

    func applicationDidFinishLaunching(_ notification: Notification) {
        player.show()
        // After the player, so a persisted-open equalizer stacks above it, as in Winamp.
        observeEQWindow()
        // The Library is the only SwiftUI window scene left, so SwiftUI opens it at launch; it is
        // meant to open from ⌘L. (`defaultLaunchBehavior(.suppressed)` needs macOS 15, the target is 14.)
        DispatchQueue.main.async { [player, equalizer] in
            for window in NSApp.windows
            where window !== player.window && window !== equalizer.window && window.identifier?.rawValue.hasPrefix("library") == true
            {
                window.close()
            }
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        player.show()
        if model.isEQWindowOpen { equalizer.show(below: player.window) }
        return false
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// Orders the equalizer window in or out to follow `model.isEQWindowOpen` (the main window's EQ button, ⌘2, the
    /// window's own close button). `withObservationTracking` fires once per change, so it re-registers itself.
    private func observeEQWindow() {
        let open = withObservationTracking {
            model.isEQWindowOpen
        } onChange: { [weak self] in
            Task { @MainActor in self?.observeEQWindow() }
        }
        if open { equalizer.show(below: player.window) } else if equalizer.window.isVisible { equalizer.hide() }
    }
}

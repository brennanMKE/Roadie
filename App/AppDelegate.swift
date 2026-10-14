import AppKit

/// Owns the player model and the main window. The main window is an AppKit `NSWindow`, not a SwiftUI
/// scene, because a borderless window needs a subclass (`SkinWindow`).
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = PlayerModel()
    private(set) lazy var player = SkinWindowController(model: model)

    func applicationDidFinishLaunching(_ notification: Notification) {
        player.show()
        // The Library is the only SwiftUI window scene left, so SwiftUI opens it at launch; it is
        // meant to open from ⌘L. (`defaultLaunchBehavior(.suppressed)` needs macOS 15, the target is 14.)
        DispatchQueue.main.async { [player] in
            for window in NSApp.windows where window !== player.window && window.identifier?.rawValue.hasPrefix("library") == true {
                window.close()
            }
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        player.show()
        return false
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

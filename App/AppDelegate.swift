import AppKit
import Observation
import SwiftUI

/// Owns the player model and the skinned windows. They are AppKit `NSWindow`s, not SwiftUI scenes, because a borderless
/// window needs a subclass (`SkinWindow`). One `SkinWindowController` per window, told apart by its `SkinWindowKind`.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = PlayerModel()
    private(set) lazy var docking = WindowDockingCoordinator(model: model)
    private(set) lazy var player = SkinWindowController(kind: .main, model: model, rootView: PlayerView())
    private(set) lazy var equalizer: SkinWindowController = {
        let controller = SkinWindowController(kind: .equalizer, model: model, rootView: EqualizerView())
        controller.onClose = { [model] in model.setEQWindowOpen(false) }
        return controller
    }()

    private(set) lazy var playlist: SkinWindowController = {
        let controller = SkinWindowController(kind: .playlist(model.playlist.steps), model: model, rootView: PlaylistView())
        controller.onClose = { [model] in model.setPlaylistWindowOpen(false) }
        return controller
    }()

    func applicationDidFinishLaunching(_ notification: Notification) {
        docking.register(player)
        docking.register(equalizer)
        docking.register(playlist)
        docking.restoreOrDefaultLayout()
        player.show()
        // After the player, so a persisted-open equalizer stacks above it, as in Winamp.
        observeEQWindow()
        observePlaylistWindow()
        docking.ensureOnScreen()
        // The Library and Skins are the only SwiftUI window scenes, so SwiftUI opens the first at launch; they are
        // meant to open from ⌘L and ⌘K. (`defaultLaunchBehavior(.suppressed)` needs macOS 15, the target is 14.)
        DispatchQueue.main.async { [player, equalizer, playlist] in
            for window in NSApp.windows
            where window !== player.window && window !== equalizer.window && window !== playlist.window
                && ["library", "skins"].contains(where: { window.identifier?.rawValue.hasPrefix($0) == true })
            {
                window.close()
            }
        }
    }

    /// A `.wsz` double-clicked in Finder (or dropped on the Dock icon, or sent with `open -a`): the same path as a drop on the
    /// window, so the skin loads through `PlayerModel.loadSkin`. The window is an `NSWindow`, not a scene, so `onOpenURL` has no
    /// scene to deliver to; the delegate gets the event on a cold launch and while running (#0043).
    func application(_ application: NSApplication, open urls: [URL]) {
        model.open(urls, replace: false)
        player.show()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        player.show()
        if model.isEQWindowOpen { equalizer.show(below: player.window) }
        if model.isPlaylistWindowOpen { playlist.show(below: playlistReference) }
        return false
    }

    func applicationWillTerminate(_ notification: Notification) {
        docking.layoutDidChange()
        model.flushQueue()
        model.sendspinController.shutdown()
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

    /// The window the playlist sits under by default: the equalizer when it is showing, else the player (Winamp's
    /// Main, Equalizer, Playlist stack).
    private var playlistReference: NSWindow { equalizer.window.isVisible ? equalizer.window : player.window }

    /// Orders the playlist window in or out to follow `model.isPlaylistWindowOpen` (the main window's PL button, ⌘3, the
    /// window's own close button).
    private func observePlaylistWindow() {
        let open = withObservationTracking {
            model.isPlaylistWindowOpen
        } onChange: { [weak self] in
            Task { @MainActor in self?.observePlaylistWindow() }
        }
        if open { playlist.show(below: playlistReference) } else if playlist.window.isVisible { playlist.hide() }
    }
}

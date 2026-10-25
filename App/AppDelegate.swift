import AppKit
import LibraryBrowser
import Observation
import SkinBrowser
import SwiftUI

/// Owns the player model and the skinned windows. They are AppKit `NSWindow`s, not SwiftUI scenes, because a borderless
/// window needs a subclass (`SkinWindow`). One `SkinWindowController` per window, told apart by its `SkinWindowKind`.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Lazy so a hosted test run (#0193) never builds one unless a test asks.
    private(set) lazy var model = PlayerModel()
    /// Sparkle (#0158). Starts only when the build carries a feed URL and a public key, so Debug builds never check.
    let updater = Updater()
    /// The Welcome window (#0169); Help › Welcome to Roadie… reopens it.
    private(set) lazy var welcome = WelcomeWindowController(model: model, onDismiss: { [model] in model.markFirstRunCompleted() })
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
        // #0193: as a unit-test host, no player model, no skinned windows, no Welcome. SwiftUI still opens the first window
        // scene, so close the Library and Skins windows as a normal launch does.
        if HostedTestRun.isActive {
            DispatchQueue.main.async {
                for window in NSApp.windows
                where ["library", "skins"].contains(where: { window.identifier?.rawValue.hasPrefix($0) == true }) {
                    window.close()
                }
            }
            return
        }
        model.updateActions = (canCheck: { [updater] in updater.canCheckForUpdates }, check: { [updater] in updater.checkForUpdates() })
        // #0169: read what earlier launches left before the default skins folder fills `skinsFolderPath`.
        let firstRun = FirstRunPolicy.decide(model.firstRunState())
        model.skinLibrary.applyDefaultFolderIfNeeded()
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
        DispatchQueue.main.async { [player, equalizer, playlist, model, welcome] in
            for window in NSApp.windows
            where window !== player.window && window !== equalizer.window && window !== playlist.window
                && ["library", "skins"].contains(where: { window.identifier?.rawValue.hasPrefix($0) == true })
            {
                window.close()
            }
            switch firstRun {
            case .skip: break
            case .markCompleted: model.markFirstRunCompleted()
            case .welcome: welcome.show(openMuseum: model.skinLibrary.folderURL.map(DefaultSkinsFolder.hasNoSkins) ?? false)
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

    /// A quit stop is in flight; a second ⌘Q terminates at once.
    private var quitStopPending = false

    /// #0121: stop the Music Assistant target before exiting (capped at `QuitStop.timeout`), then terminate.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !quitStopPending, let stopping = model.stopPlaybackForQuit() else { return .terminateNow }
        quitStopPending = true
        Task { @MainActor in
            await stopping.value
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
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

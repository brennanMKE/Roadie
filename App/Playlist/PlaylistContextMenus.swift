import AppKit
import SkinKit

/// A menu item that is its own target and runs a closure (used by the clutter bar and the playlist's pop-up menus).
final class ActionMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(title: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    @objc private func fire() { handler() }
}

/// The native menus the playlist's MISC entries pop up at the pointer (Winamp and Webamp do the same). They pop in the
/// playlist window's view, not `in: nil`, so VoiceOver and XCUITest see them (#0230): a menu popped with no view opens
/// in a window of its own that isn't in the accessibility tree.
@MainActor
enum PlaylistContextMenus {
    typealias Item = (title: String, action: () -> Void)

    /// The playlist window's hosting view, set by its `SkinWindowController` (#0230).
    static weak var host: NSView?

    /// Where a pop-up opens: the playlist window's view while that window is visible, else the key window's (#0226's
    /// menu-bar Load Playlist… with the editor closed), else nil (`in: nil`, as before #0230).
    static func popUpView(playlist: NSView?, playlistVisible: Bool, key: NSView?) -> NSView? {
        if let playlist, playlistVisible { return playlist }
        return key
    }

    /// `screen` (e.g. `NSEvent.mouseLocation`) in `view`'s coordinates, flipped or not.
    static func point(_ screen: NSPoint, in view: NSView) -> NSPoint {
        guard let window = view.window else { return screen }
        return view.convert(window.convertPoint(fromScreen: screen), from: nil)
    }

    /// Pops `menu` with its top-left at the pointer, in `popUpView`'s view.
    private static func popUpAtPointer(_ menu: NSMenu) {
        let mouse = NSEvent.mouseLocation
        let view = popUpView(playlist: host, playlistVisible: host?.window?.isVisible == true,
                             key: NSApp.keyWindow?.contentView)
        if let view {
            menu.popUp(positioning: nil, at: point(mouse, in: view), in: view)
        } else {
            menu.popUp(positioning: nil, at: mouse, in: nil)
        }
    }

    #if DEBUG
    /// Unit tests only (#0211): when set, receives the items and their enabled state instead of a menu popping up.
    /// Debug only, like #0194's stubs: Release has no hook.
    static var popUpOverride: ((_ items: [Item?], _ enabled: Bool) -> Void)?
    #endif

    /// `nil` titles are separators.
    static func popUp(_ items: [(title: String, action: () -> Void)?], enabled: Bool = true) {
        #if DEBUG
        if let popUpOverride {
            popUpOverride(items, enabled)
            return
        }
        #endif
        let menu = NSMenu()
        menu.autoenablesItems = false
        for item in items {
            if let item {
                let entry = ActionMenuItem(title: item.title, handler: item.action)
                entry.isEnabled = enabled
                menu.addItem(entry)
            } else {
                menu.addItem(.separator())
            }
        }
        // Next main-actor turn, so the skinned menu's tap finishes and it has closed first.
        Task { @MainActor in
            popUpAtPointer(menu)
        }
    }

    /// Pops `PlaylistMenu` entries at the pointer through `PlaylistMenuBuilder` (#0226). The test seam sees their
    /// titles, and enabled when every item is.
    static func popUp(_ entries: [PlaylistMenuEntry], perform: @escaping (PlaylistCommand) -> Void) {
        #if DEBUG
        if let popUpOverride {
            let items: [Item?] = entries.map { entry in
                if case .item(let item) = entry { (item.title, { perform(item.command) }) } else { nil }
            }
            let enabled = entries.allSatisfy { if case .item(let item) = $0 { item.isEnabled } else { true } }
            popUpOverride(items, enabled)
            return
        }
        #endif
        let menu = PlaylistMenuBuilder.menu(entries, perform: perform)
        Task { @MainActor in
            popUpAtPointer(menu)
        }
    }

    /// Disabled on a Music Assistant queue, which can't be sorted (#0145); the marquee says so.
    static func sort(_ model: PlayerModel) {
        if model.playlist.remote != nil { model.playlist.onRemoteRefused() }
        popUp(PlaylistMenu.sortEntries(model.playlistMenuState)) { model.perform($0) }
    }

    /// The track list's right-click menu (#0179). Runs synchronously from the event; no skinned menu is open.
    static func rowMenu(_ model: PlayerModel) -> NSMenu {
        let playlist = model.playlist
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.addItem(ActionMenuItem(title: "Play") { playlist.playFirstSelected() })
        // On a Music Assistant queue it's always Queue: a move to after the current item (#0182).
        let title = playlist.selectionIsQueued ? "Dequeue" : "Queue"
        menu.addItem(ActionMenuItem(title: title) { playlist.toggleQueueForSelection() })
        if playlist.hasUpNext {
            menu.addItem(ActionMenuItem(title: "Clear Queue") { playlist.clearUpNext() })
        }
        menu.addItem(.separator())
        menu.addItem(ActionMenuItem(title: "Remove") { playlist.removeSelected() })
        let track = playlist.fileInfoTrack
        let info = ActionMenuItem(title: "File Info…") { if let track { model.showFileInfo(for: track) } }
        info.isEnabled = track != nil
        menu.addItem(info)
        return menu
    }

    static func miscOptions(_ model: PlayerModel) {
        popUp(PlaylistMenu.miscOptionsEntries(model.playlistMenuState)) { model.perform($0) }
    }
}

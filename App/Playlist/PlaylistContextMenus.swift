import AppKit

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

/// The native menus the playlist's MISC entries pop up at the pointer (Winamp and Webamp do the same).
@MainActor
enum PlaylistContextMenus {
    typealias Item = (title: String, action: () -> Void)

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
            menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
        }
    }

    /// Disabled on a Music Assistant queue, which can't be sorted (#0145); the marquee says so.
    static func sort(_ playlist: PlaylistModel) {
        let enabled = playlist.remote == nil
        if !enabled { playlist.onRemoteRefused() }
        popUp([
            ("Sort List by Title", { playlist.sortByTitle() }),
            ("Sort List by File Name", { playlist.sortByFileName() }),
            ("Sort List by Path and File Name", { playlist.sortByPath() }),
            nil,
            ("Reverse List", { playlist.reverse() }),
            ("Randomize List", { playlist.randomize() }),
        ], enabled: enabled)
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
        popUp([("Generate HTML Playlist", { model.generateHTMLPlaylist() })])
    }
}

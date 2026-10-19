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
    /// `nil` titles are separators.
    static func popUp(_ items: [(title: String, action: () -> Void)?]) {
        let menu = NSMenu()
        menu.autoenablesItems = false
        for item in items {
            if let item {
                menu.addItem(ActionMenuItem(title: item.title, handler: item.action))
            } else {
                menu.addItem(.separator())
            }
        }
        // Next main-actor turn, so the skinned menu's tap finishes and it has closed first.
        Task { @MainActor in
            menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
        }
    }

    static func sort(_ playlist: PlaylistModel) {
        popUp([
            ("Sort List by Title", { playlist.sortByTitle() }),
            ("Sort List by File Name", { playlist.sortByFileName() }),
            ("Sort List by Path and File Name", { playlist.sortByPath() }),
            nil,
            ("Reverse List", { playlist.reverse() }),
            ("Randomize List", { playlist.randomize() }),
        ])
    }

    static func miscOptions(_ model: PlayerModel) {
        popUp([("Generate HTML Playlist", { model.generateHTMLPlaylist() })])
    }
}

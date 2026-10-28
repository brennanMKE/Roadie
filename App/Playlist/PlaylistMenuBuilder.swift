import AppKit
import SkinKit

/// Builds an `NSMenu` from `PlaylistMenu`'s entries (#0226), like `MainMenuBuilder`. In a pop-up the key equivalents
/// are display only; the menu bar's Playlist menu (`PlaylistCommands`) is what answers them.
@MainActor
enum PlaylistMenuBuilder {
    static func menu(_ entries: [PlaylistMenuEntry], perform: @escaping (PlaylistCommand) -> Void) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        for entry in entries {
            switch entry {
            case .separator:
                menu.addItem(.separator())
            case .item(let model):
                let item = ActionMenuItem(title: model.title) { perform(model.command) }
                item.isEnabled = model.isEnabled
                if let shortcut = model.shortcut {
                    item.keyEquivalent = shortcut.key
                    item.keyEquivalentModifierMask = modifierMask(shortcut.modifiers)
                }
                menu.addItem(item)
            }
        }
        return menu
    }

    static func modifierMask(_ modifiers: MainMenuShortcut.Modifiers) -> NSEvent.ModifierFlags {
        var mask: NSEvent.ModifierFlags = []
        if modifiers.contains(.command) { mask.insert(.command) }
        if modifiers.contains(.option) { mask.insert(.option) }
        if modifiers.contains(.shift) { mask.insert(.shift) }
        if modifiers.contains(.control) { mask.insert(.control) }
        return mask
    }
}

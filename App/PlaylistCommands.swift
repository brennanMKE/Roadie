import SkinKit
import SwiftUI

/// The Playlist menu (#0226): every command of the playlist editor's ADD, REM, SEL, MISC and LIST buttons, so they
/// work on any skin and with VoiceOver. Acts on the shown queue, with the editor open or closed.
struct PlaylistCommands: Commands {
    let model: PlayerModel

    var body: some Commands {
        CommandMenu("Playlist") {
            PlaylistMenuItems(model: model)
        }
    }
}

/// A view of its own so the items re-evaluate when the observed queue, selection and source change.
private struct PlaylistMenuItems: View {
    let model: PlayerModel

    var body: some View {
        ForEach(Array(PlaylistMenu.menuBarEntries(model.playlistMenuState).enumerated()), id: \.offset) { _, entry in
            switch entry {
            case .separator:
                Divider()
            case .item(let item):
                Button(item.title) { model.perform(item.command) }
                    .keyboardShortcut(item.shortcut.map(Self.shortcut))
                    .disabled(!item.isEnabled)
            }
        }
    }

    private static func shortcut(_ shortcut: MainMenuShortcut) -> KeyboardShortcut {
        var modifiers: EventModifiers = []
        if shortcut.modifiers.contains(.command) { modifiers.insert(.command) }
        if shortcut.modifiers.contains(.option) { modifiers.insert(.option) }
        if shortcut.modifiers.contains(.shift) { modifiers.insert(.shift) }
        if shortcut.modifiers.contains(.control) { modifiers.insert(.control) }
        return KeyboardShortcut(KeyEquivalent(Character(shortcut.key)), modifiers: modifiers)
    }
}

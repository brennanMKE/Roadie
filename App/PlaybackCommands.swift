import SkinKit
import SwiftUI

/// The Playback menu: the Library window, then the transport on ⌃⌘ + the Winamp key. The bare keys are handled by `SkinWindow`.
struct PlaybackCommands: Commands {
    let model: PlayerModel

    var body: some Commands {
        CommandMenu("Playback") {
            OpenLibraryWindowButton()
            Divider()
            PlaybackMenuItems(model: model)
        }
    }
}

/// A view of its own so the items re-evaluate when the observed transport state changes.
private struct PlaybackMenuItems: View {
    let model: PlayerModel

    var body: some View {
        Button("Previous") { model.perform(WinampHotkey.previous) }
            .keyboardShortcut("z", modifiers: [.command, .control])
        Button("Play") { model.perform(WinampHotkey.play) }
            .keyboardShortcut("x", modifiers: [.command, .control])
        Button("Pause") { model.perform(WinampHotkey.pause) }
            .keyboardShortcut("c", modifiers: [.command, .control])
        Button("Stop") { model.perform(WinampHotkey.stop) }
            .keyboardShortcut("v", modifiers: [.command, .control])
        Button("Next") { model.perform(WinampHotkey.next) }
            .keyboardShortcut("b", modifiers: [.command, .control])
        Divider()
        Button("Seek Back 5 Seconds") { model.perform(WinampHotkey.seekBack) }
            .keyboardShortcut(.leftArrow, modifiers: [.command, .control])
            .disabled(model.positionFraction == nil)
        Button("Seek Forward 5 Seconds") { model.perform(WinampHotkey.seekForward) }
            .keyboardShortcut(.rightArrow, modifiers: [.command, .control])
            .disabled(model.positionFraction == nil)
        Divider()
        Button("Volume Up") { model.perform(WinampHotkey.volumeUp) }
            .keyboardShortcut(.upArrow, modifiers: [.command, .control])
        Button("Volume Down") { model.perform(WinampHotkey.volumeDown) }
            .keyboardShortcut(.downArrow, modifiers: [.command, .control])
        Divider()
        Toggle("Shuffle", isOn: Binding(get: { model.isShuffled }, set: { _ in model.toggleShuffle() }))
            .keyboardShortcut("s", modifiers: [.command, .control])
        Toggle("Repeat", isOn: Binding(get: { model.isRepeating }, set: { _ in model.toggleRepeat() }))
            .keyboardShortcut("r", modifiers: [.command, .control])
        Divider()
        Button("Save Queue as Playlist\u{2026}") { model.saveQueue() }
            .disabled(!model.canSaveQueue)
        Button("Favorite Current Track") { model.favoriteCurrentTrack() }
            .keyboardShortcut("l", modifiers: [.command, .control])
            .disabled(!model.canFavoriteCurrentTrack)
    }
}

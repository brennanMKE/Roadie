import SwiftUI

/// The Skins menu: the library window, and next / previous / random skin from the index. Works with the window closed.
struct SkinsCommands: Commands {
    let model: PlayerModel

    var body: some Commands {
        CommandMenu("Skins") {
            OpenSkinsWindowButton()
            Divider()
            SkinsNavigationButtons(model: model)
        }
    }
}

private struct OpenSkinsWindowButton: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Skin Library…") { openWindow(id: "skins") }
            .keyboardShortcut("k")
    }
}

/// A view of its own so the buttons re-evaluate `canNavigate` when the index counts change.
private struct SkinsNavigationButtons: View {
    let model: PlayerModel

    var body: some View {
        let browser = model.skinBrowser
        Button("Next Skin") { browser.next() }
            .keyboardShortcut("]")
            .disabled(!browser.canNavigate)
        Button("Previous Skin") { browser.previous() }
            .keyboardShortcut("[")
            .disabled(!browser.canNavigate)
        Button("Random Skin") { browser.random() }
            .keyboardShortcut("r", modifiers: [.command, .shift])
            .disabled(!browser.canNavigate)
    }
}

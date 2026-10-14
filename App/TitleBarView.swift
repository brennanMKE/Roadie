import SkinKit
import SwiftUI

/// The main window's title bar: the strip, and on the key window the four buttons (Webamp
/// `skinSelectors.ts`: sprites only draw on the selected title bar).
struct TitleBarView: View {
    let skin: Skin
    @Environment(\.controlActiveState) private var activeState
    @Environment(\.skinWindow) private var window

    var body: some View {
        let isKey = activeState == .key
        ZStack(alignment: .topLeading) {
            SpriteImage(skin: skin, name: isKey ? "MAIN_TITLE_BAR_SELECTED" : "MAIN_TITLE_BAR")
            if isKey {
                button("MAIN_OPTIONS_BUTTON", x: 6) {}
                button("MAIN_MINIMIZE_BUTTON", x: 244) { window?.minimize() }
                button("MAIN_SHADE_BUTTON", x: 254) {}
                button("MAIN_CLOSE_BUTTON", x: 264) { window?.close() }
            }
        }
        .frame(width: 275, height: 14, alignment: .topLeading)
    }

    private func button(_ name: String, x: CGFloat, action: @escaping () -> Void) -> some View {
        Button(action: action) { EmptyView() }
            .buttonStyle(TitleBarButtonStyle(skin: skin, name: name))
            .offset(x: x, y: 3)
    }
}

/// Webamp's ClickedDiv: nothing until first pressed, then `name`; `name_DEPRESSED` while pressed.
struct TitleBarButtonStyle: ButtonStyle {
    let skin: Skin
    let name: String
    @State private var clicked = false

    func makeBody(configuration: Configuration) -> some View {
        ZStack {
            if configuration.isPressed {
                SpriteImage(skin: skin, name: "\(name)_DEPRESSED")
            } else if clicked {
                SpriteImage(skin: skin, name: name)
            } else {
                Color.clear.frame(width: 9, height: 9)
            }
        }
        .frame(width: 9, height: 9)
        .contentShape(Rectangle())
        .onChange(of: configuration.isPressed) { _, pressed in
            if pressed { clicked = true }
        }
    }
}

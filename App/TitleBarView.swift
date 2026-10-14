import SkinKit
import SwiftUI

/// The main window's title bar buttons (the strip itself is in the base image): on the key window, four
/// buttons (Webamp `skinSelectors.ts`: sprites only draw on the selected title bar).
struct TitleBarView: View {
    let skin: Skin
    @Environment(\.controlActiveState) private var activeState
    @Environment(\.skinWindow) private var window

    var body: some View {
        let isKey = activeState == .key
        ZStack(alignment: .topLeading) {
            if isKey {
                button("MAIN_OPTIONS_BUTTON", .options) {}
                button("MAIN_MINIMIZE_BUTTON", .minimize) { window?.minimize() }
                button("MAIN_SHADE_BUTTON", .shade) {}
                button("MAIN_CLOSE_BUTTON", .close) { window?.close() }
            }
        }
        .frame(width: MainWindowLayout.titleBar.width, height: MainWindowLayout.titleBar.height, alignment: .topLeading)
    }

    private func button(_ name: String, _ which: MainWindowLayout.TitleButton, action: @escaping () -> Void) -> some View {
        let rect = MainWindowLayout.rect(which)
        return Button(action: action) { EmptyView() }
            .buttonStyle(TitleBarButtonStyle(skin: skin, name: name))
            .offset(x: rect.minX, y: rect.minY)
    }
}

/// Webamp's ClickedDiv: nothing until first pressed, then `name` (nil = stays blank, the equalizer's shade button);
/// `pressedName` while pressed, `name_DEPRESSED` by default.
struct TitleBarButtonStyle: ButtonStyle {
    let skin: Skin
    let name: String?
    let pressedName: String
    @State private var clicked = false

    init(skin: Skin, name: String?, pressedName: String? = nil) {
        self.skin = skin
        self.name = name
        self.pressedName = pressedName ?? "\(name ?? "")_DEPRESSED"
    }

    func makeBody(configuration: Configuration) -> some View {
        ZStack {
            if configuration.isPressed {
                SpriteImage(skin: skin, name: pressedName)
            } else if clicked, let name {
                SpriteImage(skin: skin, name: name)
            } else {
                Color.clear.frame(width: MainWindowLayout.rect(.options).width, height: MainWindowLayout.rect(.options).height)
            }
        }
        .frame(width: MainWindowLayout.rect(.options).width, height: MainWindowLayout.rect(.options).height)
        .contentShape(Rectangle())
        .onChange(of: configuration.isPressed) { _, pressed in
            if pressed { clicked = true }
        }
    }
}

import SkinKit
import SwiftUI

/// The main window's title bar buttons (the strip itself is in the base image, or drawn by `MainShadeView` in shade
/// mode): on the key window, four buttons (Webamp `skinSelectors.ts`: sprites only draw on the selected title bar).
/// In shade mode the shade button is drawn `_SELECTED` on the key window from the start and its depressed sprite
/// shows while pressed, key or not (`skinSelectors.ts` 284-289).
struct TitleBarView: View {
    let skin: Skin
    var shaded = false
    @Environment(PlayerModel.self) private var model
    @Environment(\.controlActiveState) private var activeState
    @Environment(\.skinWindow) private var window

    var body: some View {
        let isKey = activeState == .key
        ZStack(alignment: .topLeading) {
            if isKey {
                button("MAIN_OPTIONS_BUTTON", .options) {}
                button("MAIN_MINIMIZE_BUTTON", .minimize) { window?.minimize() }
            }
            if shaded {
                shadeButton(name: isKey ? "MAIN_SHADE_BUTTON_SELECTED" : nil)
            } else if isKey {
                shadeButton(name: "MAIN_SHADE_BUTTON")
            }
            if isKey {
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

    private func shadeButton(name: String?) -> some View {
        let rect = MainWindowLayout.rect(.shade)
        return Button { model.toggleMainWindowShade() } label: { EmptyView() }
            .buttonStyle(
                TitleBarButtonStyle(
                    skin: skin, name: name, pressedName: shaded ? "MAIN_SHADE_BUTTON_SELECTED_DEPRESSED" : nil,
                    showsBeforeClick: shaded))
            .offset(x: rect.minX, y: rect.minY)
    }
}

/// Webamp's ClickedDiv: nothing until first pressed, then `name` (nil = stays blank, the equalizer's shade button);
/// `pressedName` while pressed, `name_DEPRESSED` by default. `showsBeforeClick` draws `name` from the start (the main
/// window's shade button in shade mode). `group` shares the "clicked" flag between buttons, as `EqTitleButtons` does.
struct TitleBarButtonStyle: ButtonStyle {
    let skin: Skin
    let name: String?
    let pressedName: String
    let showsBeforeClick: Bool
    let group: Binding<Bool>?
    @State private var ownClicked = false

    init(
        skin: Skin, name: String?, pressedName: String? = nil, showsBeforeClick: Bool = false, group: Binding<Bool>? = nil
    ) {
        self.skin = skin
        self.name = name
        self.pressedName = pressedName ?? "\(name ?? "")_DEPRESSED"
        self.showsBeforeClick = showsBeforeClick
        self.group = group
    }

    private var clicked: Bool { group?.wrappedValue ?? ownClicked }

    func makeBody(configuration: Configuration) -> some View {
        ZStack {
            if configuration.isPressed {
                SpriteImage(skin: skin, name: pressedName)
            } else if (clicked || showsBeforeClick), let name {
                SpriteImage(skin: skin, name: name)
            } else {
                Color.clear.frame(width: MainWindowLayout.rect(.options).width, height: MainWindowLayout.rect(.options).height)
            }
        }
        .frame(width: MainWindowLayout.rect(.options).width, height: MainWindowLayout.rect(.options).height)
        .contentShape(Rectangle())
        .onChange(of: configuration.isPressed) { _, pressed in
            if pressed {
                ownClicked = true
                group?.wrappedValue = true
            }
        }
    }
}

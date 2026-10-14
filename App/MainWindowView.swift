import MusicBackendKit
import SkinKit
import SwiftUI

/// The 275x116 main window, laid out in skin pixel coordinates.
/// Positions are from Webamp's css/main-window.css.
struct MainWindowView: View {
    @Environment(PlayerModel.self) private var model
    let skin: Skin

    var body: some View {
        ZStack(alignment: .topLeading) {
            SpriteImage(skin: skin, name: "MAIN_WINDOW_BACKGROUND")
            // TODO: borderless window with title-bar dragging and region.txt shape (AppKit).
            SpriteImage(skin: skin, name: "MAIN_TITLE_BAR_SELECTED")

            MainWindowStatusLayer(skin: skin, status: model.mainWindowStatus, toggleTimeMode: model.toggleTimeMode)

            transportButton("MAIN_PREVIOUS_BUTTON", x: 16, y: 88, action: model.previous)
            transportButton("MAIN_PLAY_BUTTON", x: 39, y: 88, action: model.play)
            transportButton("MAIN_PAUSE_BUTTON", x: 62, y: 88, action: model.pause)
            transportButton("MAIN_STOP_BUTTON", x: 85, y: 88, action: model.stop)
            transportButton("MAIN_NEXT_BUTTON", x: 108, y: 88, action: model.next)
            transportButton("MAIN_EJECT_BUTTON", x: 136, y: 89, action: model.eject)

            MarqueeView(skin: skin, text: model.marqueeText)
        }
        .frame(width: 275, height: 116, alignment: .topLeading)
        // TODO: position/volume/balance sliders, shuffle/repeat, visualizer.
    }

    private func transportButton(_ name: String, x: CGFloat, y: CGFloat, action: @escaping () -> Void) -> some View {
        Button(action: action) { EmptyView() }
            .buttonStyle(SpriteButtonStyle(skin: skin, name: name))
            .offset(x: x, y: y)
    }
}

/// Draws a sprite at 1:1 skin pixels with nearest-neighbor sampling.
struct SpriteImage: View {
    let skin: Skin
    let name: String

    var body: some View {
        if let image = skin.image(for: name) {
            Image(decorative: image, scale: 1)
                .interpolation(.none)
        } else if let sprite = SkinSprites.byName[name]?.sprite {
            // TODO: fall back to a generated base skin instead of an empty frame.
            Color.clear.frame(width: CGFloat(sprite.width), height: CGFloat(sprite.height))
        }
    }
}

/// Shows `<name>` normally and `<name>_ACTIVE` while pressed.
struct SpriteButtonStyle: ButtonStyle {
    let skin: Skin
    let name: String

    func makeBody(configuration: Configuration) -> some View {
        SpriteImage(skin: skin, name: configuration.isPressed ? "\(name)_ACTIVE" : name)
    }
}

import MusicBackendKit
import SkinKit
import SwiftUI

/// The 275x116 main window, laid out in skin pixel coordinates.
/// Positions are from Webamp's css/main-window.css.
struct MainWindowView: View {
    @Environment(PlayerModel.self) private var model
    @Environment(\.controlActiveState) private var activeState
    let skin: Skin

    var body: some View {
        if model.isMainWindowShaded {
            MainShadeView(skin: skin)
        } else {
            normalBody
        }
    }

    private var normalBody: some View {
        ZStack(alignment: .topLeading) {
            baseLayer
            TitleBarView(skin: skin)
            ClutterBarView(skin: skin)

            RemoteClock(anchor: model.remoteClockAnchor) { now in
                MainWindowStatusLayer(skin: skin, status: model.mainWindowStatus(at: now), toggleTimeMode: model.toggleTimeMode)
            }

            transportButton(.previous, action: model.previous)
            transportButton(.play, action: model.play)
            transportButton(.pause, action: model.pause)
            transportButton(.stop, action: model.stop)
            transportButton(.next, action: model.next)
            transportButton(.eject, action: model.eject)

            volumeSlider
            balanceSlider
            RemoteClock(anchor: model.remoteClockAnchor) { positionSlider(at: $0) }

            toggleButton(.shuffle, selected: model.isShuffled, action: model.toggleShuffle)
            toggleButton(.repeatAll, selected: model.isRepeating, action: model.toggleRepeat)
            toggleButton(.equalizer, selected: model.isEQWindowOpen, action: model.toggleEQWindow)
            toggleButton(.playlist, selected: model.isPlaylistWindowOpen, action: model.togglePlaylistWindow)

            VisualizerView(model: model.visualizer)
                .offset(x: MainWindowLayout.visualizer.minX, y: MainWindowLayout.visualizer.minY)

            MarqueeView(skin: skin, text: model.marqueeText)
        }
        .frame(width: MainWindowLayout.size.width, height: MainWindowLayout.size.height, alignment: .topLeading)
    }

    /// Background, title-bar strip, clutter bar and the unpressed transport sprites, drawn once per skin by
    /// `MainWindowRenderer.renderBase` (the same pixels `skintool --png` writes).
    @ViewBuilder private var baseLayer: some View {
        if let base = model.mainWindowBase {
            Image(decorative: activeState == .key ? base.focused : base.unfocused, scale: 1)
                .interpolation(.none)
        } else {
            SpriteImage(skin: skin, name: "MAIN_WINDOW_BACKGROUND")
        }
    }

    private var volumeSlider: some View {
        SkinSlider(
            skin: skin, slider: MainSliders.volume, backgroundName: "MAIN_VOLUME_BACKGROUND",
            thumbName: "MAIN_VOLUME_THUMB", thumbPressedName: "MAIN_VOLUME_THUMB_SELECTED",
            frame: MainSliders.volumeFrame(model.volume), fraction: Double(model.volume),
            onChange: { model.setVolume(Float($0)) }, onCommit: { _ in model.endSliderDrag() })
    }

    private var balanceSlider: some View {
        SkinSlider(
            skin: skin, slider: MainSliders.balance, backgroundName: "MAIN_BALANCE_BACKGROUND",
            thumbName: "MAIN_BALANCE_THUMB", thumbPressedName: "MAIN_BALANCE_THUMB_ACTIVE",
            frame: MainSliders.balanceFrame(model.balance), fraction: MainSliders.fraction(forBalance: model.balance),
            onChange: { model.setBalance(MainSliders.balance(forFraction: $0)) }, onCommit: { _ in model.endSliderDrag() })
    }

    private func positionSlider(at now: Date) -> some View {
        let scrub: Double? = if case .position(let fraction) = model.sliderFocus { fraction } else { nil }
        return SkinSlider(
            skin: skin, slider: MainSliders.position, backgroundName: "MAIN_POSITION_SLIDER_BACKGROUND",
            thumbName: "MAIN_POSITION_SLIDER_THUMB", thumbPressedName: "MAIN_POSITION_SLIDER_THUMB_SELECTED",
            frame: nil, fraction: scrub ?? model.positionFraction(at: now),
            onChange: { model.scrub(toFraction: $0) }, onCommit: { model.seek(toFraction: $0) })
    }

    private func toggleButton(_ toggle: MainSliders.Toggle, selected: Bool, action: @escaping () -> Void) -> some View {
        let frame = MainSliders.frame(of: toggle)
        return Button(action: action) { EmptyView() }
            .buttonStyle(ToggleSpriteButtonStyle(skin: skin, toggle: toggle, selected: selected))
            .offset(x: frame.origin.x, y: frame.origin.y)
    }

    private func transportButton(_ control: MainWindowLayout.Transport, action: @escaping () -> Void) -> some View {
        let rect = MainWindowLayout.rect(control)
        return Button(action: action) { EmptyView() }
            .buttonStyle(SpriteButtonStyle(skin: skin, control: control))
            .offset(x: rect.minX, y: rect.minY)
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
            // Only sheets the generated base doesn't provide (EQ_EX, GEN) reach this; see GeneratedBaseSkin.
            Color.clear.frame(width: CGFloat(sprite.width), height: CGFloat(sprite.height))
        }
    }
}

/// A transport button: the unpressed sprite is in the base image, so this draws only the `_ACTIVE` sprite while
/// pressed and otherwise a clear, clickable area of the sprite's size.
struct SpriteButtonStyle: ButtonStyle {
    let skin: Skin
    let control: MainWindowLayout.Transport

    func makeBody(configuration: Configuration) -> some View {
        let size = MainWindowLayout.rect(control).size
        ZStack(alignment: .topLeading) {
            if configuration.isPressed {
                SpriteImage(skin: skin, name: MainWindowLayout.spriteName(control, pressed: true))
            }
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        .contentShape(Rectangle())
    }
}

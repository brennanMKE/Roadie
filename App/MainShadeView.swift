import SkinKit
import SwiftUI

/// The 275x14 shade strip: title bar with buttons, mini time, small visualizer, invisible transport buttons over the
/// strip's painted ones, and the 17x7 position slider. Positions are `MainShadeLayout` (SkinKit, tested headless).
struct MainShadeView: View {
    @Environment(PlayerModel.self) private var model
    @Environment(\.controlActiveState) private var activeState
    let skin: Skin

    var body: some View {
        ZStack(alignment: .topLeading) {
            SpriteImage(skin: skin, name: activeState == .key ? "MAIN_SHADE_BACKGROUND_SELECTED" : "MAIN_SHADE_BACKGROUND")
            TitleBarView(skin: skin, shaded: true)

            RemoteClock(anchor: model.remoteClockAnchor) { now in
                let status = model.mainWindowStatus(at: now)
                MiniTimeView(skin: skin, status: status, toggleTimeMode: model.toggleTimeMode)
                    .skinDisplay(AXID.Shade.Main.time, label: "Time", value: status.accessibility.time)
                    .accessibilityAddTraits(.isButton)
            }
            .offset(x: MainShadeLayout.miniTimeOrigin.x, y: MainShadeLayout.miniTimeOrigin.y)

            VisualizerView(model: model.visualizer, size: MainShadeLayout.visualizerFrame.size, axID: AXID.Shade.Main.visualizer)
                .offset(x: MainShadeLayout.visualizerFrame.minX, y: MainShadeLayout.visualizerFrame.minY)

            transportButton(.previous, AXID.Shade.Main.previous, "Previous", action: model.previous)
            transportButton(.play, AXID.Shade.Main.play, "Play", action: model.play)
            transportButton(.pause, AXID.Shade.Main.pause, "Pause", action: model.pause)
            transportButton(.stop, AXID.Shade.Main.stop, "Stop", action: model.stop)
            transportButton(.next, AXID.Shade.Main.next, "Next", action: model.next)
            transportButton(.eject, AXID.Shade.Main.eject, "Eject", action: model.eject)

            RemoteClock(anchor: model.remoteClockAnchor) { positionSlider(at: $0) }
        }
        .frame(width: MainShadeLayout.size.width, height: MainShadeLayout.size.height, alignment: .topLeading)
    }

    private func positionSlider(at now: Date) -> some View {
        let scrub: Double? = if case .position(let fraction) = model.sliderFocus { fraction } else { nil }
        let fraction = scrub ?? model.positionFraction(at: now)
        return SkinSlider(
            skin: skin, slider: MainSliders.shadePosition, backgroundName: "MAIN_SHADE_POSITION_BACKGROUND",
            thumbName: MainSliders.shadePositionThumbName(fraction: fraction ?? 0),
            thumbPressedName: MainSliders.shadePositionThumbName(fraction: fraction ?? 0),
            frame: nil, fraction: fraction,
            onChange: { model.scrub(toFraction: $0) }, onCommit: { model.seek(toFraction: $0) })
            .skinSlider(AXID.Shade.Main.position, label: "Position", value: model.positionAccessibilityValue(at: now))
    }

    private func transportButton(
        _ control: MainShadeLayout.Transport, _ id: String, _ label: String, action: @escaping () -> Void
    ) -> some View {
        let rect = MainShadeLayout.frame(of: control)
        return Button(action: action) {
            Color.clear.frame(width: rect.width, height: rect.height).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .skinControl(id, label: label)
        .offset(x: rect.minX, y: rect.minY)
    }
}

/// The mini time: five text.bmp characters. Blinks like the big time while paused (the off phase draws spaces, not
/// nothing, so the skin's text background stays); a click toggles elapsed/remaining (MiniTime.tsx 48).
struct MiniTimeView: View {
    let skin: Skin
    let status: MainWindowStatus
    let toggleTimeMode: () -> Void

    var body: some View {
        ZStack(alignment: .topLeading) {
            image(MiniTime.blank)
            if status.blinksTime {
                BlinkingView { image(MiniTime.characters(status)) }
            } else {
                image(MiniTime.characters(status))
            }
            Color.clear
                .frame(width: MainShadeLayout.miniTimeHitArea.width, height: MainShadeLayout.miniTimeHitArea.height)
                .contentShape(Rectangle())
                .onTapGesture(perform: toggleTimeMode)
        }
        .frame(
            width: MainShadeLayout.miniTimeHitArea.width, height: MainShadeLayout.miniTimeHitArea.height,
            alignment: .topLeading)
    }

    @ViewBuilder private func image(_ characters: [String]) -> some View {
        if let image = skin.miniTimeImage(characters) {
            Image(decorative: image, scale: 1).interpolation(.none)
        }
    }
}

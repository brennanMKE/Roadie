import AudioCore
import SkinKit
import SwiftUI

/// The equalizer window's content: the 275x116 skin drawn at the window's scale, or the same "No Skin Loaded"
/// placeholder as the player so the window is never blank.
struct EqualizerView: View {
    @Environment(PlayerModel.self) private var model

    var body: some View {
        let height = (model.isEQWindowShaded ? EQLayout.shadeSize : EQLayout.windowSize).height
        Group {
            if let skin = model.skin {
                Group {
                    if model.isEQWindowShaded { EQShadeView(skin: skin) } else { EqualizerWindowView(skin: skin) }
                }
                .scaleEffect(model.scale, anchor: .topLeading)
                .frame(width: EQLayout.windowSize.width * model.scale, height: height * model.scale, alignment: .topLeading)
            } else {
                ContentUnavailableView {
                    Label("No Skin Loaded", systemImage: "paintpalette")
                } description: {
                    Text(model.placeholderText)
                } actions: {
                    Button("Open Skin…") { model.openSkin() }
                }
                .frame(width: EQLayout.windowSize.width * model.scale, height: height * model.scale)
                .background(.windowBackground, in: .rect(cornerRadius: 8))
            }
        }
    }
}

/// The 275x116 equalizer window in skin pixels. Positions, value math and the graph all come from `EQLayout` and
/// `EQGraph` (SkinKit, tested headless); this only draws and forwards pointer positions to `PlayerModel`.
struct EqualizerWindowView: View {
    @Environment(PlayerModel.self) private var model
    let skin: Skin

    var body: some View {
        let eq = model.eq
        ZStack(alignment: .topLeading) {
            SpriteImage(skin: skin, name: "EQ_WINDOW_BACKGROUND")
            EQTitleBarView(skin: skin)

            toggleButton(EQLayout.onButton, base: "EQ_ON_BUTTON", selected: eq.isEnabled, action: model.toggleEQEnabled)
            // Webamp does not support AUTO (toggleEqAuto always dispatches false): it depresses while held, never selects.
            toggleButton(EQLayout.autoButton, base: "EQ_AUTO_BUTTON", selected: false) {}
            EQPresetsMenu(skin: skin)
                .offset(x: EQLayout.presetsButton.minX, y: EQLayout.presetsButton.minY)

            EQGraphView(skin: skin, eq: eq)
                .offset(x: EQLayout.graph.minX, y: EQLayout.graph.minY)

            EQPreampView(skin: skin, gain: eq.preamp)
            levelLabel(EQLayout.plus12, value: 100)
            levelLabel(EQLayout.zero, value: EQLayout.midValue)
            levelLabel(EQLayout.minus12, value: 0)
            EQBandStripView(skin: skin, gains: eq.gains)
        }
        .frame(width: EQLayout.windowSize.width, height: EQLayout.windowSize.height, alignment: .topLeading)
    }

    private func toggleButton(_ rect: CGRect, base: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) { EmptyView() }
            .buttonStyle(EQToggleButtonStyle(skin: skin, base: base, selected: selected, size: rect.size))
            .offset(x: rect.minX, y: rect.minY)
    }

    /// The invisible +12 / 0 / -12 dB click targets set every band at once.
    private func levelLabel(_ rect: CGRect, value: Double) -> some View {
        Button { model.setAllEQBands(value: value) } label: {
            Color.clear.frame(width: rect.width, height: rect.height).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .offset(x: rect.minX, y: rect.minY)
    }
}

/// The title bar strip (selected on the key window) and its two buttons: shade, which draws only its pressed sprite, and
/// close, which hides the window. In shade mode the strip is the shade background and close has its own sprites. The two
/// buttons share one "clicked" flag that resets when the window stops being key (`EqTitleButtons.tsx`).
struct EQTitleBarView: View {
    let skin: Skin
    var shaded = false
    @Environment(PlayerModel.self) private var model
    @Environment(\.controlActiveState) private var activeState
    @Environment(\.skinWindow) private var window
    @State private var clicked = false

    var body: some View {
        let isKey = activeState == .key
        ZStack(alignment: .topLeading) {
            SpriteImage(skin: skin, name: strip(isKey: isKey))
            if isKey {
                button(
                    EQLayout.shadeButton, name: nil,
                    pressedName: shaded ? "EQ_MINIMIZE_BUTTON_ACTIVE" : "EQ_MAXIMIZE_BUTTON_ACTIVE"
                ) { model.toggleEQWindowShade() }
                button(
                    EQLayout.closeButton, name: shaded ? "EQ_SHADE_CLOSE_BUTTON" : "EQ_CLOSE_BUTTON",
                    pressedName: shaded ? "EQ_SHADE_CLOSE_BUTTON_ACTIVE" : "EQ_CLOSE_BUTTON_ACTIVE"
                ) { window?.close() }
            }
        }
        .frame(width: EQLayout.windowSize.width, height: EQLayout.titleBarHeight, alignment: .topLeading)
        .onChange(of: isKey) { _, _ in clicked = false }
    }

    private func strip(isKey: Bool) -> String {
        if shaded { return isKey ? "EQ_SHADE_BACKGROUND_SELECTED" : "EQ_SHADE_BACKGROUND" }
        return isKey ? "EQ_TITLE_BAR_SELECTED" : "EQ_TITLE_BAR"
    }

    private func button(_ rect: CGRect, name: String?, pressedName: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { EmptyView() }
            .buttonStyle(TitleBarButtonStyle(skin: skin, name: name, pressedName: pressedName, group: $clicked))
            .offset(x: rect.minX, y: rect.minY)
    }
}

/// The 275x14 equalizer shade strip: the title bar and, drawn over the strip's own tracks, the main window's volume and
/// balance thumbs (3x7, picked by thirds). The sliders drive the same model calls as the main window's.
struct EQShadeView: View {
    @Environment(PlayerModel.self) private var model
    let skin: Skin

    var body: some View {
        ZStack(alignment: .topLeading) {
            EQTitleBarView(skin: skin, shaded: true)
            slider(
                MainSliders.eqShadeVolume, prefix: "EQ_SHADE_VOLUME_SLIDER", fraction: Double(model.volume),
                onChange: { model.setVolume(Float($0)) })
            slider(
                MainSliders.eqShadeBalance, prefix: "EQ_SHADE_BALANCE_SLIDER", fraction: MainSliders.fraction(forBalance: model.balance),
                onChange: { model.setBalance(MainSliders.balance(forFraction: $0)) })
        }
        .frame(width: EQLayout.shadeSize.width, height: EQLayout.shadeSize.height, alignment: .topLeading)
    }

    private func slider(_ slider: MainSliders.Slider, prefix: String, fraction: Double, onChange: @escaping (Double) -> Void) -> some View {
        let name: String =
            switch MainSliders.shadeSegment(fraction: fraction) {
            case .left: prefix + "_LEFT"
            case .center: prefix + "_CENTER"
            case .right: prefix + "_RIGHT"
            }
        return SkinSlider(
            skin: skin, slider: slider, backgroundName: nil, thumbName: name, thumbPressedName: name, frame: nil,
            fraction: fraction, onChange: onChange, onCommit: { _ in model.endSliderDrag() })
    }
}

/// ON and AUTO: `base`, plus `_SELECTED` when on and `_DEPRESSED` while pressed (`_SELECTED_DEPRESSED` for both).
struct EQToggleButtonStyle: ButtonStyle {
    let skin: Skin
    let base: String
    let selected: Bool
    let size: CGSize

    func makeBody(configuration: Configuration) -> some View {
        SpriteImage(skin: skin, name: base + (selected ? "_SELECTED" : "") + (configuration.isPressed ? "_DEPRESSED" : ""))
            .frame(width: size.width, height: size.height, alignment: .topLeading)
            .contentShape(Rectangle())
    }
}

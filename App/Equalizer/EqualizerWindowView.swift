import AudioCore
import SkinKit
import SwiftUI

/// The equalizer window's content: the 275x116 skin drawn at the window's scale, or the same "No Skin Loaded"
/// placeholder as the player so the window is never blank.
struct EqualizerView: View {
    @Environment(PlayerModel.self) private var model

    var body: some View {
        Group {
            if let skin = model.skin {
                EqualizerWindowView(skin: skin)
                    .scaleEffect(model.scale, anchor: .topLeading)
                    .frame(
                        width: EQLayout.windowSize.width * model.scale, height: EQLayout.windowSize.height * model.scale,
                        alignment: .topLeading)
            } else {
                ContentUnavailableView {
                    Label("No Skin Loaded", systemImage: "paintpalette")
                } description: {
                    Text(model.placeholderText)
                } actions: {
                    Button("Open Skin…") { model.openSkin() }
                }
                .frame(width: EQLayout.windowSize.width * model.scale, height: EQLayout.windowSize.height * model.scale)
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

/// The title bar strip (selected on the key window) and its two buttons: shade, which only shows its pressed sprite
/// until #0031 gives it an action, and close, which hides the window.
struct EQTitleBarView: View {
    let skin: Skin
    @Environment(\.controlActiveState) private var activeState
    @Environment(\.skinWindow) private var window

    var body: some View {
        let isKey = activeState == .key
        ZStack(alignment: .topLeading) {
            SpriteImage(skin: skin, name: isKey ? "EQ_TITLE_BAR_SELECTED" : "EQ_TITLE_BAR")
            if isKey {
                button(EQLayout.shadeButton, name: nil, pressedName: "EQ_MAXIMIZE_BUTTON_ACTIVE") {}
                button(EQLayout.closeButton, name: "EQ_CLOSE_BUTTON", pressedName: "EQ_CLOSE_BUTTON_ACTIVE") { window?.close() }
            }
        }
        .frame(width: EQLayout.windowSize.width, height: EQLayout.titleBarHeight, alignment: .topLeading)
    }

    private func button(_ rect: CGRect, name: String?, pressedName: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { EmptyView() }
            .buttonStyle(TitleBarButtonStyle(skin: skin, name: name, pressedName: pressedName))
            .offset(x: rect.minX, y: rect.minY)
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

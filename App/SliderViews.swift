import SkinKit
import SwiftUI

/// One of the main window's three sliders: a background, a thumb and a drag gesture. All geometry and
/// value math come from `MainSliders`; this view only draws and forwards pointer positions.
struct SkinSlider: View {
    let skin: Skin
    let slider: MainSliders.Slider
    /// nil when the strip behind already paints the track (the equalizer's shade sliders).
    let backgroundName: String?
    let thumbName: String
    let thumbPressedName: String
    /// Frame of a multi-frame background (volume, balance); nil for the position bar.
    let frame: Int?
    /// 0...1, or nil to hide the thumb (and ignore drags).
    let fraction: Double?
    /// Called on every pointer move with the 0...1 fraction.
    let onChange: (Double) -> Void
    /// Called once on release with the final fraction.
    let onCommit: (Double) -> Void

    /// Identifier, label and value for accessibility (#0199); set with `skinSlider(_:label:value:)`.
    var accessibility: (id: String, label: String, value: String)?

    @GestureState private var isPressed = false

    /// This slider exposed as one accessibility slider. `value` is its value description; `AXValue` is the 0...100
    /// position, and an increment or decrement moves it 2 % and commits.
    func skinSlider(_ id: String, label: String, value: String) -> SkinSlider {
        var copy = self
        copy.accessibility = (id, label, value)
        return copy
    }

    var body: some View {
        if let accessibility {
            // A native Slider as the accessibility representation: SwiftUI (macOS) gives a custom adjustable element
            // the role AXUnknown and no AXValue, so XCUITest read an empty value (#0200). This one is an AXSlider
            // whose AXValue is the position in percent and whose AXValueDescription is `accessibility.value`.
            content
                .accessibilityRepresentation {
                    Slider(value: accessibilityPercent, in: 0...100, step: 2)
                        .disabled(fraction == nil)
                }
                .accessibilityIdentifier(accessibility.id)
                .accessibilityLabel(accessibility.label)
                .accessibilityValue(accessibility.value)
        } else {
            content
        }
    }

    /// The fraction as 0...100 for the accessibility slider; setting it moves the slider and commits.
    private var accessibilityPercent: Binding<Double> {
        Binding(
            get: { (fraction ?? 0) * 100 },
            set: { percent in
                guard fraction != nil else { return }
                let target = min(max(percent / 100, 0), 1)
                onChange(target)
                onCommit(target)
            })
    }

    private var content: some View {
        ZStack(alignment: .topLeading) {
            background
            if let fraction {
                SpriteImage(skin: skin, name: isPressed ? thumbPressedName : thumbName)
                    .frame(width: slider.thumbSize.width, height: slider.thumbSize.height, alignment: .topLeading)
                    .offset(x: slider.thumbX(for: fraction) - slider.origin.x, y: slider.thumbInsetY)
            }
            Color.clear
                .frame(width: slider.size.width, height: slider.size.height)
                .contentShape(Rectangle())
                .gesture(drag)
        }
        .frame(width: slider.size.width, height: slider.size.height, alignment: .topLeading)
        .offset(x: slider.origin.x, y: slider.origin.y)
    }

    @ViewBuilder private var background: some View {
        if let backgroundName {
            trackImage(backgroundName)
        }
    }

    @ViewBuilder private func trackImage(_ backgroundName: String) -> some View {
        if let frame {
            if let image = skin.image(for: backgroundName, frame: frame) {
                Image(decorative: image, scale: 1).interpolation(.none)
            }
        } else {
            SpriteImage(skin: skin, name: backgroundName)
        }
    }

    private var drag: some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .local)
            .updating($isPressed) { _, state, _ in state = true }
            .onChanged { value in
                guard fraction != nil else { return }
                onChange(slider.fraction(forPointerX: value.location.x + slider.origin.x))
            }
            .onEnded { value in
                guard fraction != nil else { return }
                onCommit(slider.fraction(forPointerX: value.location.x + slider.origin.x))
            }
    }
}

/// Draws a toggle's sprite for its selected and pressed state.
struct ToggleSpriteButtonStyle: ButtonStyle {
    let skin: Skin
    let toggle: MainSliders.Toggle
    let selected: Bool

    func makeBody(configuration: Configuration) -> some View {
        SpriteImage(skin: skin, name: MainSliders.spriteName(toggle, selected: selected, pressed: configuration.isPressed))
    }
}

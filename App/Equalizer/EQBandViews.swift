import AudioCore
import SkinKit
import SwiftUI

/// One band's 14x63 background frame and thumb. No gesture of its own: the strip and the preamp attach theirs.
struct EQBandView: View {
    let skin: Skin
    /// Webamp's 0...100 slider scale.
    let value: Double
    let isHeld: Bool

    var body: some View {
        ZStack(alignment: .topLeading) {
            if let image = skin.image(for: "EQ_SLIDER_BACKGROUND", bandFrame: EQLayout.frame(forValue: value)) {
                Image(decorative: image, scale: 1).interpolation(.none)
            }
            SpriteImage(skin: skin, name: isHeld ? "EQ_SLIDER_THUMB_SELECTED" : "EQ_SLIDER_THUMB")
                .frame(width: EQLayout.thumbSize.width, height: EQLayout.thumbSize.height, alignment: .topLeading)
                .offset(x: EQLayout.thumbInsetX, y: EQLayout.thumbY(forValue: value))
        }
        .frame(width: EQLayout.bandSize.width, height: EQLayout.bandSize.height, alignment: .topLeading)
    }
}

/// The ten bands under one drag gesture, so a drag that starts in the strip moves each band the pointer enters
/// (Webamp's `clickOriginatedInEq`). The preamp has its own gesture and never joins.
struct EQBandStripView: View {
    @Environment(PlayerModel.self) private var model
    let skin: Skin
    let gains: [Float]

    var body: some View {
        ZStack(alignment: .topLeading) {
            ForEach(0..<EQLayout.bandCount, id: \.self) { i in
                let origin = EQLayout.bandOrigin(i)
                let value = EQLayout.value(forGain: gains[i])
                EQBandView(skin: skin, value: value, isHeld: model.sliderFocus == .equalizer(band: i))
                    .eqSlider(AXID.EQ.band(i), label: "Band \(i + 1)", gain: gains[i], value: value) {
                        model.setEQBand(i, value: $0)
                        model.endEQDrag()
                    }
                    .offset(x: origin.x - EQLayout.bandStrip.minX, y: 0)
            }
            Color.clear
                .frame(width: EQLayout.bandStrip.width, height: EQLayout.bandStrip.height)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0, coordinateSpace: .local)
                        .onChanged { drag in
                            let band = EQLayout.bandIndex(atX: drag.location.x + EQLayout.bandStrip.minX)
                            model.setEQBand(band, value: EQLayout.value(forPointerY: drag.location.y))
                        }
                        .onEnded { _ in model.endEQDrag() })
        }
        .frame(width: EQLayout.bandStrip.width, height: EQLayout.bandStrip.height, alignment: .topLeading)
        .offset(x: EQLayout.bandStrip.minX, y: EQLayout.bandStrip.minY)
    }
}

struct EQPreampView: View {
    @Environment(PlayerModel.self) private var model
    let skin: Skin
    let gain: Float

    var body: some View {
        let value = EQLayout.value(forGain: gain)
        EQBandView(skin: skin, value: value, isHeld: model.sliderFocus == .equalizer(band: nil))
            .contentShape(Rectangle())
            .eqSlider(AXID.EQ.preamp, label: "Preamp", gain: gain, value: value) {
                model.setEQPreamp(value: $0)
                model.endEQDrag()
            }
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .local)
                    .onChanged { drag in model.setEQPreamp(value: EQLayout.value(forPointerY: drag.location.y)) }
                    .onEnded { _ in model.endEQDrag() })
            .offset(x: EQLayout.preampOrigin.x, y: EQLayout.preampOrigin.y)
    }
}

/// The response curve and preamp line, drawn by `EQGraph` from the skin's graph sprites. Draws nothing when the skin
/// has no line colours, as in Webamp.
struct EQGraphView: View {
    let skin: Skin
    let eq: EQState

    var body: some View {
        if let image = EQGraph.render(skin: skin, values: eq.gains.map(EQLayout.value(forGain:)), preamp: EQLayout.value(forGain: eq.preamp)) {
            Image(decorative: image, scale: 1).interpolation(.none)
        } else {
            Color.clear.frame(width: EQGraph.size.width, height: EQGraph.size.height)
        }
    }
}

extension EQLayout {
    /// A gain in dB with one decimal, as the accessibility value of a band, the preamp and the graph (#0199).
    static func accessibilityValue(_ gain: Float) -> String { String(format: "%.1f", Double(gain)) }
}

extension View {
    /// An EQ slider as one adjustable accessibility element; `set` takes Webamp's 0...100 value (`adjust` moves 2).
    func eqSlider(_ id: String, label: String, gain: Float, value: Double, set: @escaping (Double) -> Void) -> some View {
        accessibilityElement(children: .ignore)
            .accessibilityIdentifier(id)
            .accessibilityLabel(label)
            .accessibilityValue(EQLayout.accessibilityValue(gain))
            .accessibilityAdjustableAction { direction in
                switch direction {
                case .increment: set(min(value + 2, 100))
                case .decrement: set(max(value - 2, 0))
                @unknown default: break
                }
            }
    }
}

import AppKit
import SkinKit
import VisualizationKit

/// Classic and MilkDrop presets in one window (#0257, design docs/design/visualization.md §3.4): owns a classic
/// renderer and an optional MilkDrop one, routes each preset to the renderer that can load it, and crossfades the two
/// views when the kind changes. The crossfade is driven by `draw(at:)` time, so it pauses with the render loop.
@MainActor
final class MixedVisualizer: VisualizationRenderer {
    let classic: any VisualizationRenderer
    let milk: (any VisualizationRenderer)?
    private let container = MixedContainerView()
    private(set) var active: any VisualizationRenderer
    /// The renderer fading out, while a crossfade runs.
    private(set) var outgoing: (any VisualizationRenderer)?
    private var fadeDuration: TimeInterval = 0
    private var fadeStart: TimeInterval?

    var view: NSView { container }
    var kindName: String { active.kindName }
    var problems: [String] { active.problems }

    init(classic: any VisualizationRenderer, milk: (any VisualizationRenderer)?) {
        self.classic = classic
        self.milk = milk
        active = classic
        for inner in [classic, milk].compactMap({ $0 }) {
            let sub = inner.view
            sub.frame = container.bounds
            sub.autoresizingMask = [.width, .height]
            sub.setAccessibilityElement(false)
            sub.isHidden = inner !== classic
            sub.alphaValue = inner === classic ? 1 : 0
            container.addSubview(sub)
        }
    }

    private func renderer(for preset: VisualizationPreset) -> (any VisualizationRenderer)? {
        if classic.canLoad(preset) { return classic }
        if let milk, milk.canLoad(preset) { return milk }
        return nil
    }

    func canLoad(_ preset: VisualizationPreset) -> Bool { renderer(for: preset) != nil }

    func load(_ preset: VisualizationPreset, transition: TimeInterval) throws {
        guard let incoming = renderer(for: preset) else { throw MixedVisualizerError.noRenderer }
        if incoming === active {
            try active.load(preset, transition: transition)
            return
        }
        // MilkDrop drops audio queued while it wasn't drawing (#0243), so the picture doesn't lag.
        if incoming === milk { incoming.reset() }
        try incoming.load(preset, transition: 0)
        finishCrossfade()
        let previous = active
        active = incoming
        incoming.view.isHidden = false
        if transition > 0 {
            outgoing = previous
            fadeDuration = transition
            fadeStart = nil
            incoming.view.alphaValue = 0
            container.addSubview(incoming.view, positioned: .above, relativeTo: previous.view)
        } else {
            incoming.view.alphaValue = 1
            hide(previous)
        }
    }

    func feed(_ samples: UnsafeBufferPointer<Float>, channels: Int, sampleRate: Double) {
        active.feed(samples, channels: channels, sampleRate: sampleRate)
        outgoing?.feed(samples, channels: channels, sampleRate: sampleRate)
    }

    func draw(at time: TimeInterval) {
        if let outgoing {
            let start = fadeStart ?? time
            fadeStart = start
            let progress = fadeDuration > 0 ? (time - start) / fadeDuration : 1
            if progress >= 1 {
                finishCrossfade()
            } else {
                active.view.alphaValue = CGFloat(max(progress, 0))
                outgoing.draw(at: time)
            }
        }
        active.draw(at: time)
    }

    func setReducedMotion(_ on: Bool) {
        classic.setReducedMotion(on)
        milk?.setReducedMotion(on)
    }

    func setColors(_ colors: [SkinKit.RGBColor]) {
        classic.setColors(colors)
        milk?.setColors(colors)
    }

    private func finishCrossfade() {
        guard let outgoing else { return }
        active.view.alphaValue = 1
        hide(outgoing)
        self.outgoing = nil
        fadeStart = nil
    }

    private func hide(_ renderer: any VisualizationRenderer) {
        renderer.view.isHidden = true
        renderer.view.alphaValue = 0
    }
}

enum MixedVisualizerError: Error {
    /// Neither renderer can draw the preset.
    case noRenderer
}

/// Holds both renderers' views; the host view's accessibility stays on it.
@MainActor
final class MixedContainerView: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        autoresizesSubviews = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }
}

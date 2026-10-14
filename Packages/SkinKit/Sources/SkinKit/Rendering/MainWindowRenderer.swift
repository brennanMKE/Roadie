import CoreGraphics
import Foundation

/// Draws the 275x116 main window into a `CGContext` with no AppKit and no window, from the same SkinKit
/// helpers and the same `MainWindowLayout` table the app's views use. Output is nearest-neighbour, top-left
/// origin, device RGB, premultiplied RGBA8.
public enum MainWindowRenderer {
    /// The static layers the app draws once per skin: MAIN_WINDOW_BACKGROUND, the title-bar strip for `focused`,
    /// MAIN_CLUTTER_BAR_BACKGROUND and the six unpressed transport sprites. No title-bar buttons (Webamp draws
    /// none until one is clicked).
    public static func renderBase(skin: Skin, focused: Bool, scale: Int = 1) -> CGImage {
        let scale = max(scale, 1)
        let context = makeContext(scale: scale)
        let drawer = SpriteDrawer(context: context, skin: skin)
        context.scaleBy(x: CGFloat(scale), y: CGFloat(scale))
        drawBase(drawer, focused: focused)
        return context.makeImage()!
    }

    /// The dynamic layers over `base` (a `renderBase` image at the same `scale`).
    public static func renderDynamic(over base: CGImage, skin: Skin, state: MainWindowState, scale: Int = 1) -> CGImage {
        let scale = max(scale, 1)
        let context = makeContext(scale: scale)
        let drawer = SpriteDrawer(context: context, skin: skin)
        drawer.draw(
            base, in: CGRect(x: 0, y: 0, width: Int(MainWindowLayout.size.width) * scale, height: Int(MainWindowLayout.size.height) * scale))
        context.scaleBy(x: CGFloat(scale), y: CGFloat(scale))
        drawDynamic(drawer, state: state, scale: scale)
        return context.makeImage()!
    }

    /// `renderBase` + `renderDynamic`; `clipToRegion` clips to `skin.region.normal` without antialiasing (like
    /// `SkinRegion.maskImage`), so pixels outside the shape stay transparent, as in Webamp's screenshots.
    public static func render(skin: Skin, state: MainWindowState, scale: Int = 1, clipToRegion: Bool = false) -> CGImage {
        let scale = max(scale, 1)
        let context = makeContext(scale: scale)
        draw(into: context, at: .zero, skin: skin, state: state, scale: scale, clipToRegion: clipToRegion)
        return context.makeImage()!
    }

    /// The primitive the others wrap: draws the window with its top-left at `origin` (device pixels) into a
    /// caller-owned context whose CTM is y-down (device pixels, origin top-left). Leaves the context's state as found.
    public static func draw(
        into context: CGContext, at origin: CGPoint, skin: Skin, state: MainWindowState, scale: Int, clipToRegion: Bool
    ) {
        let scale = max(scale, 1)
        context.saveGState()
        defer { context.restoreGState() }
        context.translateBy(x: origin.x, y: origin.y)
        context.scaleBy(x: CGFloat(scale), y: CGFloat(scale))
        context.interpolationQuality = .none
        context.setShouldAntialias(false)
        context.setAllowsAntialiasing(false)
        if clipToRegion, let polygons = skin.region.normal {
            context.addPath(SkinRegion.path(polygons, scale: 1))
            context.clip(using: .winding)
        }
        let drawer = SpriteDrawer(context: context, skin: skin)
        drawBase(drawer, focused: state.focused)
        drawDynamic(drawer, state: state, scale: scale)
    }

    // MARK: Context

    /// A y-down, device-pixel context of the window at `scale`.
    private static func makeContext(scale: Int) -> CGContext {
        let width = Int(MainWindowLayout.size.width) * scale
        let height = Int(MainWindowLayout.size.height) * scale
        let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.interpolationQuality = .none
        context.setShouldAntialias(false)
        context.setAllowsAntialiasing(false)
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1, y: -1)
        return context
    }

    // MARK: Layers

    private static func drawBase(_ d: SpriteDrawer, focused: Bool) {
        if let background = d.skin.image(for: "MAIN_WINDOW_BACKGROUND") {
            d.draw(background, at: .zero)
        } else {
            d.context.setFillColor(CGColor(colorSpace: CGColorSpaceCreateDeviceRGB(), components: [0.1, 0.1, 0.1, 1])!)
            d.context.fill(CGRect(origin: .zero, size: MainWindowLayout.size))
        }
        d.draw(focused ? "MAIN_TITLE_BAR_SELECTED" : "MAIN_TITLE_BAR", at: MainWindowLayout.titleBar.origin)
        d.draw("MAIN_CLUTTER_BAR_BACKGROUND", at: MainWindowLayout.clutterBar.origin)
        for control in MainWindowLayout.Transport.allCases {
            let rect = MainWindowLayout.rect(control)
            guard let image = d.skin.image(for: MainWindowLayout.spriteName(control, pressed: false)) else { continue }
            d.draw(image, at: rect.origin, clippedTo: rect)
        }
    }

    private static func drawDynamic(_ d: SpriteDrawer, state: MainWindowState, scale: Int) {
        let skin = d.skin
        let status = state.status

        // Webamp's DOM order: #play-pause, then #work-indicator over its first 3 px.
        if let indicator = status.indicator {
            d.draw(indicator, at: MainWindowLayout.playIndicator)
        }
        if let work = status.workIndicator, let image = skin.image(for: work) {
            d.draw(image, at: MainWindowLayout.workIndicator.origin, clippedTo: MainWindowLayout.workIndicator)
        }

        if status.showsTime {
            d.draw(status.showsMinus ? skin.minusName : skin.noMinusName, at: skin.minusFrame.origin)
            let digits = status.digits
            let values = [digits.minutesTens, digits.minutesOnes, digits.secondsTens, digits.secondsOnes]
            for (value, x) in zip(values, MainWindowLayout.digitXs) {
                if let value { d.draw(skin.digitSpriteName(value), at: CGPoint(x: x, y: MainWindowLayout.digitY)) }
            }
        }

        drawVisualizer(d, state: state.visualizer, scale: scale)

        if let image = skin.textImage(MarqueeLayout.loopText(state.marqueeText)) {
            let offset = MarqueeLayout.stepOffset(text: state.marqueeText, step: state.marqueeStep, pixels: state.marqueePixels)
            d.draw(
                image, at: CGPoint(x: MainWindowLayout.marquee.minX - CGFloat(offset), y: MainWindowLayout.marquee.minY),
                clippedTo: MainWindowLayout.marquee)
        }
        if let kbps = status.kbps, let image = skin.textImage(kbps) { d.draw(image, at: MainWindowLayout.kbps) }
        if let khz = status.khz, let image = skin.textImage(khz) { d.draw(image, at: MainWindowLayout.khz) }
        d.draw(status.monoSelected ? "MAIN_MONO_SELECTED" : "MAIN_MONO", at: MainWindowLayout.mono)
        d.draw(status.stereoSelected ? "MAIN_STEREO_SELECTED" : "MAIN_STEREO", at: MainWindowLayout.stereo)

        drawSlider(
            d, slider: MainSliders.volume, background: "MAIN_VOLUME_BACKGROUND", thumb: "MAIN_VOLUME_THUMB",
            frame: MainSliders.volumeFrame(state.volume), fraction: Double(state.volume))
        drawSlider(
            d, slider: MainSliders.balance, background: "MAIN_BALANCE_BACKGROUND", thumb: "MAIN_BALANCE_THUMB",
            frame: MainSliders.balanceFrame(state.balance), fraction: MainSliders.fraction(forBalance: state.balance))

        for (toggle, selected) in [(MainSliders.Toggle.equalizer, state.eqOpen), (.playlist, state.playlistOpen)] {
            d.draw(MainSliders.spriteName(toggle, selected: selected, pressed: false), at: MainSliders.frame(of: toggle).origin)
        }

        drawSlider(
            d, slider: MainSliders.position, background: "MAIN_POSITION_SLIDER_BACKGROUND",
            thumb: "MAIN_POSITION_SLIDER_THUMB", frame: nil, fraction: state.position)

        for (toggle, selected) in [(MainSliders.Toggle.shuffle, state.shuffle), (.repeatAll, state.repeatOn)] {
            d.draw(MainSliders.spriteName(toggle, selected: selected, pressed: false), at: MainSliders.frame(of: toggle).origin)
        }
    }

    private static func drawSlider(
        _ d: SpriteDrawer, slider: MainSliders.Slider, background: String, thumb: String, frame: Int?, fraction: Double?
    ) {
        if let frame {
            if let image = d.skin.image(for: background, frame: frame) { d.draw(image, at: slider.origin) }
        } else {
            d.draw(background, at: slider.origin)
        }
        if let fraction {
            d.draw(thumb, at: CGPoint(x: slider.thumbX(for: fraction), y: slider.origin.y + slider.thumbInsetY))
        }
    }

    private static func drawVisualizer(_ d: SpriteDrawer, state: MainWindowState.Visualizer, scale: Int) {
        // VisualizerModel.setScale: the bars sit 2 px lower at 1x.
        let pushDown = scale >= 2 ? 0 : 2
        var renderer = VisRenderer(colors: d.skin.visColors)
        renderer.clear()
        switch state {
        case .off: return
        case .spectrum(let heights, let peaks): renderer.drawBars(heights: heights, peaks: peaks, pushDown: pushDown)
        case .oscilloscope(let samples): renderer.drawOscilloscope(samples, pushDown: pushDown)
        }
        if let image = renderer.makeImage() { d.draw(image, at: MainWindowLayout.visualizer.origin) }
    }
}

/// Wraps a y-down context (skin pixels after the caller's scale) with the few draws the renderer needs.
struct SpriteDrawer {
    let context: CGContext
    let skin: Skin

    func draw(_ name: String, at point: CGPoint) {
        guard let image = skin.image(for: name) else { return }
        draw(image, at: point)
    }

    func draw(_ image: CGImage, at point: CGPoint) {
        draw(image, in: CGRect(x: point.x, y: point.y, width: CGFloat(image.width), height: CGFloat(image.height)))
    }

    func draw(_ image: CGImage, at point: CGPoint, clippedTo rect: CGRect) {
        context.saveGState()
        context.clip(to: rect)
        draw(image, at: point)
        context.restoreGState()
    }

    /// CGContext.draw assumes y up; flip locally so the image is upright in the y-down space.
    func draw(_ image: CGImage, in rect: CGRect) {
        context.saveGState()
        context.translateBy(x: rect.minX, y: rect.maxY)
        context.scaleBy(x: 1, y: -1)
        context.draw(image, in: CGRect(x: 0, y: 0, width: rect.width, height: rect.height))
        context.restoreGState()
    }
}

import AppKit
import AudioCore
import QuartzCore
import SkinKit
import VisualizationKit

enum ClassicVisualizerError: Error {
    /// A `.milk` preset; only `MilkVisualizer` draws those.
    case notClassic
}

/// Roadie's own full-window take on Winamp's built-in visualizer (design §3.3): five `ClassicStyle`s drawn into a
/// small bitmap (240 pixels wide, aspect-matched to the view) shown nearest-neighbour, in the skin's `viscolor.txt`
/// colours. Deterministic for a given input, no Metal.
@MainActor
final class ClassicVisualizer: VisualizationRenderer {
    static let width = 240
    static let fftSize = 1_024
    /// With no audio for this long (draw time), the spectrum decays to zero, as Winamp's bars do when stopped.
    static let silenceAfter: TimeInterval = 0.1

    let kindName = "classic"
    private(set) var problems: [String] = []
    var view: NSView { canvas }

    private let canvas = ClassicCanvasView()
    private(set) var style: ClassicStyle = .spectrum
    private var colors: [UInt32]
    private var width = ClassicVisualizer.width
    private var height = 135
    private var pixels: [UInt32]
    private var reducedMotion = false

    // Audio: the newest `fftSize` frames, mono mix and per channel.
    private var mono = [Float](repeating: 0, count: ClassicVisualizer.fftSize)
    private var left = [Float](repeating: 0, count: ClassicVisualizer.fftSize)
    private var right = [Float](repeating: 0, count: ClassicVisualizer.fftSize)
    private var analyzer: SpectrumAnalyzer?
    private var analyzerRate: Double = 0
    private var spectrum = [Float](repeating: 0, count: VisBars.columnCount)
    private var scopeScratch = [Float](repeating: 0, count: 76)
    private var bars = VisBars()
    private var fedSinceDraw = false
    private var lastAudioTime: TimeInterval?
    private var lastDrawTime: TimeInterval?
    private var accumulator = 0.0

    /// The bars' heights (0...15) after the last draw, for tests.
    var barHeights: [Int] { bars.heights }

    init(colors: [SkinKit.RGBColor]) {
        self.colors = Self.pack(colors)
        pixels = []
        bars.maxHeight = 15
        canvas.onResize = { [weak self] size in self?.resize(to: size) }
        resize(to: CGSize(width: 640, height: 360))
    }

    func setColors(_ colors: [SkinKit.RGBColor]) {
        self.colors = Self.pack(colors)
        render()
    }

    func setReducedMotion(_ on: Bool) { reducedMotion = on }

    /// Classic presets only; `.milk` ones go to `MilkVisualizer` through `MixedVisualizer` (#0257).
    func canLoad(_ preset: VisualizationPreset) -> Bool {
        if case .classic = preset.kind { return true }
        return false
    }

    func load(_ preset: VisualizationPreset, transition: TimeInterval) throws {
        guard case .classic(let next) = preset.kind else { throw ClassicVisualizerError.notClassic }
        problems = []
        if transition > 0 { canvas.crossfade(duration: transition) }
        style = next
        render()
    }

    func feed(_ samples: UnsafeBufferPointer<Float>, channels: Int, sampleRate: Double) {
        guard channels > 0, sampleRate > 0 else { return }
        let frames = samples.count / channels
        guard frames > 0 else { return }
        if analyzer == nil || analyzerRate != sampleRate {
            analyzer = SpectrumAnalyzer(fftSize: Self.fftSize, sampleRate: sampleRate)
            analyzerRate = sampleRate
        }
        let n = Self.fftSize
        let take = min(frames, n)
        let keep = n - take
        for i in 0..<keep {
            mono[i] = mono[i + take]
            left[i] = left[i + take]
            right[i] = right[i + take]
        }
        let start = frames - take
        for i in 0..<take {
            let base = (start + i) * channels
            let l = samples[base]
            let r = channels > 1 ? samples[base + 1] : l
            left[keep + i] = l
            right[keep + i] = r
            mono[keep + i] = (l + r) * 0.5
        }
        guard let analyzer else { return }
        mono.withUnsafeBufferPointer { m in
            spectrum.withUnsafeMutableBufferPointer { sp in
                scopeScratch.withUnsafeMutableBufferPointer { sc in analyzer.analyze(m, spectrum: sp, scope: sc) }
            }
        }
        fedSinceDraw = true
    }

    func draw(at time: TimeInterval) {
        let dt = max(lastDrawTime.map { time - $0 } ?? 1.0 / 60, 0)
        lastDrawTime = time
        if fedSinceDraw {
            lastAudioTime = time
            fedSinceDraw = false
        }
        let silent = lastAudioTime.map { time - $0 > Self.silenceAfter } ?? true
        if silent {
            for i in spectrum.indices { spectrum[i] = 0 }
            for i in mono.indices { mono[i] = 0; left[i] = 0; right[i] = 0 }
        }
        // Webamp's falloff in fixed 60 Hz steps, as `VisualizerModel.tick` does.
        accumulator += min(dt, 0.1)
        let steps = min(Int(accumulator * 60 + 1e-9), 6)
        accumulator -= Double(steps) / 60
        if accumulator > 1.0 / 60 || accumulator < 0 { accumulator = 0 }
        for _ in 0..<steps { bars.step(spectrum) }
        render()
    }

    // MARK: Drawing

    private func resize(to size: CGSize) {
        guard size.width > 0, size.height > 0 else { return }
        let h = Int((Double(Self.width) * Double(size.height) / Double(size.width)).rounded())
        let clamped = min(max(h, 90), 240)
        guard clamped != height || pixels.isEmpty else { return }
        width = Self.width
        height = clamped
        pixels = [UInt32](repeating: 0, count: width * height)
        render()
    }

    private func color(_ index: Int) -> UInt32 { colors[min(max(index, 0), colors.count - 1)] }

    private func render() {
        guard !pixels.isEmpty else { return }
        let background = color(0)
        for i in pixels.indices { pixels[i] = background }
        switch style {
        case .spectrum: drawBars(top: 0, bottom: height, mirrored: false)
        case .oscilloscope: drawScope(mono, top: 0, bottom: height)
        case .spectrumAndScope:
            drawBars(top: 0, bottom: height, mirrored: false)
            drawScope(mono, top: 0, bottom: height)
        case .mirror: drawBars(top: 0, bottom: height, mirrored: true)
        case .stereoScope:
            drawScope(left, top: 0, bottom: height / 2)
            drawScope(right, top: height / 2, bottom: height)
        }
        canvas.show(makeImage())
    }

    /// 75 bars (VisBars' 0...15) scaled to the bitmap: colours 2 (top) to 17 (bottom), peaks in colour 23. Mirrored
    /// bars grow up and down from the centre line.
    private func drawBars(top: Int, bottom: Int, mirrored: Bool) {
        let columns = VisBars.columnCount
        let span = bottom - top
        let full = mirrored ? span / 2 : span
        let base = mirrored ? top + span / 2 : bottom
        for c in 0..<columns {
            let x0 = c * width / columns
            let x1 = max(x0 + 1, (c + 1) * width / columns - 1)
            let barHeight = bars.heights[c] * full / 16
            let peak = bars.peaks[c]
            for x in x0..<min(x1, width) {
                for k in 0..<barHeight {
                    let colorIndex = 17 - min(15, k * 16 / max(full, 1))
                    let barColor = color(colorIndex)
                    let y = base - 1 - k
                    if y >= top, y < bottom { pixels[y * width + x] = barColor }
                    if mirrored {
                        let y2 = base + k
                        if y2 >= top, y2 < bottom { pixels[y2 * width + x] = barColor }
                    }
                }
                if peak > 0 {
                    let offset = min(peak * full / 16, full - 1)
                    let y = base - 1 - offset
                    if y >= top, y < bottom { pixels[y * width + x] = color(23) }
                    if mirrored {
                        let y2 = base + offset
                        if y2 >= top, y2 < bottom { pixels[y2 * width + x] = color(23) }
                    }
                }
            }
        }
    }

    /// A line through the newest window, `width` points, colours 18 (centre) to 22 (edges).
    private func drawScope(_ samples: [Float], top: Int, bottom: Int) {
        let span = bottom - top
        guard span > 1 else { return }
        let mid = Double(top) + Double(span - 1) / 2
        var previous: Int?
        for x in 0..<width {
            let s = Double(min(max(samples[x * samples.count / width], -1), 1))
            let y = min(max(Int((mid - s * Double(span - 1) / 2).rounded()), top), bottom - 1)
            let from = previous ?? y
            for yy in min(from, y)...max(from, y) {
                let distance = abs(Double(yy) - mid) / (Double(span) / 2)
                pixels[yy * width + x] = color(18 + min(4, Int(distance * 5)))
            }
            previous = y
        }
    }

    private func makeImage() -> CGImage? {
        let data = pixels.withUnsafeBytes { Data($0) }
        guard let provider = CGDataProvider(data: data as CFData) else { return nil }
        return CGImage(
            width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: VisRenderer.bitmapInfo, provider: provider,
            decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }

    /// Premultiplied BGRA (`VisRenderer.bitmapInfo`): 0xAARRGGBB in a little-endian word.
    private static func pack(_ colors: [SkinKit.RGBColor]) -> [UInt32] {
        let source = colors.isEmpty ? VisRenderer.defaultColors : colors
        var packed = source.map { 0xFF00_0000 | UInt32($0.red) << 16 | UInt32($0.green) << 8 | UInt32($0.blue) }
        while packed.count < 24 { packed.append(packed.last ?? 0xFF00_0000) }
        return packed
    }
}

/// The classic visualizer's view: a layer showing the bitmap nearest-neighbour, and a second layer holding the
/// outgoing frame while it crossfades out.
final class ClassicCanvasView: NSView {
    var onResize: ((CGSize) -> Void)?
    private let current = CALayer()
    private let outgoing = CALayer()

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 640, height: 360))
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        for sub in [current, outgoing] {
            sub.magnificationFilter = .nearest
            sub.contentsGravity = .resize
            sub.frame = bounds
            sub.actions = ["contents": NSNull(), "bounds": NSNull(), "position": NSNull()]
            layer?.addSublayer(sub)
        }
        outgoing.opacity = 0
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        current.frame = bounds
        outgoing.frame = bounds
        CATransaction.commit()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        onResize?(newSize)
    }

    func show(_ image: CGImage?) {
        current.contents = image
    }

    /// The frame on screen now fades out over `duration` above the new one.
    func crossfade(duration: TimeInterval) {
        outgoing.contents = current.contents
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 1
        fade.toValue = 0
        fade.duration = duration
        outgoing.opacity = 0
        outgoing.add(fade, forKey: "crossfade")
    }
}

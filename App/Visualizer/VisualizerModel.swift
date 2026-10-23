import AppKit
import AudioCore
import Observation
import QuartzCore
import SkinKit
import os

/// Owns the main-window visualizer: a display link ticks while audio plays, the analyzer's read cursor
/// supplies a fresh window each tick, `VisBars` applies Webamp's falloff in fixed 60 Hz steps and
/// `VisRenderer` paints the 76x16 image. Only `VisualizerView` reads `image`, so the rest of the window
/// does not re-render 60 times a second.
@MainActor
@Observable
final class VisualizerModel {
    /// Webamp's VISUALIZER_ORDER: bars, oscilloscope, none.
    enum Mode: Int, CaseIterable {
        case spectrum, oscilloscope, off

        /// The clutter bar's V menu labels.
        var title: String {
            switch self {
            case .spectrum: "Spectrum Analyzer"
            case .oscilloscope: "Oscilloscope"
            case .off: "Off"
            }
        }
    }

    private static let modeKey = "visualizerMode"
    private static let signposter = OSSignposter(subsystem: "co.sstools.roadie", category: "Visualizer")
    private static let log = Logger(subsystem: "co.sstools.roadie", category: "Visualizer")

    private(set) var mode: Mode
    /// nil draws nothing (stopped, or mode off).
    private(set) var image: CGImage?
    /// Image pixels per skin pixel: 2 for the doubled shade strip's 152x10 image, else 1.
    private(set) var pointScale = 1

    @ObservationIgnored private let player: Player
    @ObservationIgnored private var renderer: VisRenderer
    @ObservationIgnored private var bars = VisBars()
    @ObservationIgnored private var colors: [SkinKit.RGBColor]
    @ObservationIgnored private var isShaded = false
    @ObservationIgnored private var scale: CGFloat = 2
    @ObservationIgnored private var link: CADisplayLink?
    @ObservationIgnored private var fallbackTimer: Timer?
    @ObservationIgnored private var target: DisplayLinkTarget?
    @ObservationIgnored private var accumulator = 0.0
    @ObservationIgnored private var lastSampleCount = -1
    @ObservationIgnored private var lastScope: [Float] = []
    @ObservationIgnored private var running = false
    /// Time of the previous tick, so the read cursor advances by real elapsed time (dropped frames included).
    @ObservationIgnored private var lastTickTime: CFTimeInterval?

    private static let silence = [Float](repeating: 0, count: VisBars.columnCount)

    init(player: Player, colors: [SkinKit.RGBColor]) {
        self.player = player
        self.colors = colors
        renderer = VisRenderer(colors: colors)
        mode = UserDefaults.standard.object(forKey: Self.modeKey)
            .flatMap { $0 as? Int }.flatMap(Mode.init(rawValue:)) ?? .spectrum
    }

    /// Spectrum, then oscilloscope, then off, then spectrum again.
    func cycleMode() {
        setMode(Mode(rawValue: (mode.rawValue + 1) % Mode.allCases.count) ?? .spectrum)
    }

    func setMode(_ mode: Mode) {
        self.mode = mode
        UserDefaults.standard.set(mode.rawValue, forKey: Self.modeKey)
        // Off skips the analysis, so the cursor stood still; re-lag it rather than replay old audio.
        if mode == .spectrum { player.analyzer.resetCursor() }
        // Paused and stopped players do not tick, so repaint the frozen state in the new mode.
        if player.state == .paused { render() } else if mode == .off { image = nil }
    }

    func setColors(_ colors: [SkinKit.RGBColor]) {
        self.colors = colors
        applyLayout()
    }

    /// Winamp draws the main-window vis 2 px lower at 1x and flush when doubled.
    func setScale(_ scale: CGFloat) {
        setLayout(shaded: isShaded, scale: scale)
    }

    /// The main window's 76x16 visualizer, or the shade strip's 76x5 one (at device resolution when `scale` is 2 or
    /// more, as Webamp draws it). Survives a skin switch: `setColors` re-runs it.
    func setLayout(shaded: Bool, scale: CGFloat) {
        isShaded = shaded
        self.scale = scale
        applyLayout()
    }

    private func applyLayout() {
        let layout: VisLayout = isShaded ? .shade(pixelDensity: scale >= 2 ? 2 : 1) : .main
        renderer = VisRenderer(colors: colors, layout: layout)
        pointScale = layout.pointScale
        bars.maxHeight = layout.maxHeight
        bars.smallVis = isShaded
        bars.pushDown = isShaded ? 0 : (scale >= 2 ? 0 : 2)
        if player.state == .paused { render() } else { image = nil }
    }

    // MARK: Lifecycle

    func start() {
        guard !running else { return }
        running = true
        makeLink()
        observeState()
        applyState()
    }

    func stop() {
        running = false
        link?.invalidate(); link = nil
        fallbackTimer?.invalidate(); fallbackTimer = nil
        target = nil
        lastTickTime = nil
    }

    private func makeLink() {
        let target = DisplayLinkTarget(model: self)
        self.target = target
        if let screen = NSScreen.main {
            let link = screen.displayLink(target: target, selector: #selector(DisplayLinkTarget.tick(_:)))
            link.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 60, preferred: 60)
            link.isPaused = true
            link.add(to: .main, forMode: .common)
            self.link = link
        } else {
            Self.log.error("no main screen; the visualizer falls back to a 60 Hz timer")
            let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak target] _ in
                MainActor.assumeIsolated { target?.fire() }
            }
            RunLoop.main.add(timer, forMode: .common)
            fallbackTimer = timer
        }
    }

    /// Follows `player.state`; `withObservationTracking` fires once per change, so it is re-armed each time.
    private func observeState() {
        guard running else { return }
        withObservationTracking {
            _ = player.state
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.applyState()
                self?.observeState()
            }
        }
    }

    private func setTicking(_ ticking: Bool) {
        if let link {
            if link.isPaused == ticking { player.analyzer.resetCursor() }
            link.isPaused = !ticking
        }
        lastTickTime = nil
        fallbackTimer?.fireDate = ticking ? .now : .distantFuture
    }

    private func applyState() {
        switch player.state {
        case .stopped:
            setTicking(false)
            let (pushDown, maxHeight, smallVis) = (bars.pushDown, bars.maxHeight, bars.smallVis)
            bars = VisBars()
            bars.pushDown = pushDown
            bars.maxHeight = maxHeight
            bars.smallVis = smallVis
            lastSampleCount = -1
            accumulator = 0
            image = nil
        case .paused:
            setTicking(false)   // the last image stays up, frozen
        case .playing, .loading:
            setTicking(true)
        }
    }

    // MARK: Ticking

    /// `now` is the frame's timestamp; `nominal` the frame duration, used for the first tick after a resume.
    /// `targetTimestamp - timestamp` alone would ignore dropped frames, and the cursor would fall a frame
    /// further behind the audio with each one.
    fileprivate func tick(now: CFTimeInterval, nominal: Double) {
        let dt = max(lastTickTime.map { now - $0 } ?? nominal, 0)
        lastTickTime = now
        guard mode != .off else { return }   // image is already nil; no analysis while off
        tick(dt: dt)
    }

    /// `dt` is real elapsed time: unclamped for the read cursor (it re-lags after long gaps), capped for the bars.
    private func tick(dt: Double) {
        let state = Self.signposter.beginInterval("tick")
        defer { Self.signposter.endInterval("tick", state) }

        let frame = player.analyzer.frame(elapsed: dt)
        let fresh = frame.map { $0.sampleCount != lastSampleCount } ?? false
        if let frame {
            lastSampleCount = frame.sampleCount
            lastScope = frame.scope
        }
        accumulator += min(dt, 0.1)
        let steps = min(Int(accumulator * 60), 4)
        accumulator -= Double(steps) / 60
        if accumulator > 1.0 / 60 { accumulator = 0 }   // a long stall does not fast-forward the bars
        var spectrum = fresh ? (frame?.spectrum ?? Self.silence) : Self.silence
        if renderer.layout.columnCount == 37 {
            // The 1x shade strip has half the columns: average adjacent pairs of the 75 bands.
            spectrum = (0..<37).map { ((spectrum[safe: 2 * $0] ?? 0) + (spectrum[safe: 2 * $0 + 1] ?? 0)) / 2 }
        }
        for _ in 0..<steps { bars.step(spectrum) }
        render()
    }

    private func render() {
        guard mode != .off else { image = nil; return }
        renderer.clear()
        switch mode {
        case .spectrum:
            renderer.drawBars(heights: bars.heights, peaks: bars.peaks, pushDown: bars.pushDown)
        case .oscilloscope:
            renderer.drawOscilloscope(lastScope, pushDown: bars.pushDown)
        case .off:
            break
        }
        image = renderer.makeImage()
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}

/// `CADisplayLink` retains its target, so this trampoline holds the model weakly.
@MainActor
private final class DisplayLinkTarget: NSObject {
    weak var model: VisualizerModel?

    init(model: VisualizerModel) { self.model = model }

    @objc func tick(_ link: CADisplayLink) {
        model?.tick(now: link.timestamp, nominal: link.targetTimestamp - link.timestamp)
    }

    func fire() { model?.tick(now: CACurrentMediaTime(), nominal: 1.0 / 60) }
}

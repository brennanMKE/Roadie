import Foundation

/// Everything `MainWindowRenderer` draws that changes: a value made of the landed types. Every field has a
/// default so later additions do not break callers.
public struct MainWindowState: Sendable, Equatable {
    public enum Visualizer: Sendable, Equatable {
        case off
        /// `VisRenderer.drawBars` input; empty arrays draw the background only.
        case spectrum(heights: [Int], peaks: [Int])
        case oscilloscope([Float])
    }

    public var status: MainWindowStatus
    /// MAIN_TITLE_BAR_SELECTED versus MAIN_TITLE_BAR.
    public var focused = true
    /// Drawn through `MarqueeLayout.loopText` / `stepOffset`.
    public var marqueeText = ""
    public var marqueeStep = 0
    public var marqueePixels = 0
    public var volume: Float = 0.78
    public var balance: Float = 0
    /// nil hides the thumb, as the app does while nothing is loaded.
    public var position: Double?
    public var shuffle = false
    public var repeatOn = false
    public var eqOpen = false
    public var playlistOpen = false
    public var visualizer: Visualizer = .off

    public init(status: MainWindowStatus) {
        self.status = status
    }

    /// Stopped, focused, marquee "SkinAmp" (MarqueeText.idle), everything else default.
    public static let idle: MainWindowState = {
        var state = MainWindowState(status: MainWindowStatus(
            transport: .stopped, timeMode: .elapsed, elapsed: 0, duration: 0,
            bitrateKbps: nil, sampleRate: nil, channels: nil))
        state.marqueeText = "SkinAmp"
        return state
    }()

    /// Webamp's `?screenshot=1` state (packages/webamp-demo screenshotInitialState.ts): playing, 3 s of a 5 s
    /// track, 128 kbps / 44.1 kHz / stereo, the marquee at step 0, volume 78 %, shuffle and repeat on,
    /// EQ and playlist open, bar visualizer with no data.
    public static let webampScreenshot: MainWindowState = {
        var state = MainWindowState(status: MainWindowStatus(
            transport: .playing, timeMode: .elapsed, elapsed: 3, duration: 5,
            bitrateKbps: 128, sampleRate: 44100, channels: 2))
        state.marqueeText = "1. DJ Mike Llama - Llama Whipping Intro (0:05)"
        state.volume = 0.78
        state.balance = 0
        state.position = 0.6
        state.shuffle = true
        state.repeatOn = true
        state.eqOpen = true
        state.playlistOpen = true
        state.visualizer = .spectrum(heights: [], peaks: [])
        return state
    }()
}

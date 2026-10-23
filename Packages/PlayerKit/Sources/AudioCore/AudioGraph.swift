import AVFoundation
import CoreAudio
import os

private let log = Logger(subsystem: "co.sstools.roadie", category: "AudioOutput")

/// Owns the AVAudioEngine and its nodes: player -> EQ -> main mixer -> output.
@MainActor
final class AudioGraph {
    let engine = AVAudioEngine()
    let playerNode = AVAudioPlayerNode()
    /// Ten Winamp bands, configured in `init`; driven by `Player.eq` via `apply(_:)`.
    let eq = AVAudioUnitEQ(numberOfBands: 10)
    /// The one format player -> eq -> mixer is connected at: the output's rate, stereo.
    /// nil until the first `start()`. `AVAudioPlayerNode` converts each file to it.
    private(set) var processingFormat: AVAudioFormat?

    /// Sample rate of the node timeline (nil until the first `start()`).
    var processingSampleRate: Double? { processingFormat?.sampleRate }

    var mainMixerNode: AVAudioMixerNode { engine.mainMixerNode }

    /// Visualizer tap on the main mixer (post-EQ, post-volume), re-installed on every `start()`.
    let analyzer: AnalyzerTap
    /// Tests that install their own mixer tap turn this off (one tap per bus).
    var installsAnalyzer = true

    /// 0...1, linear.
    var volume: Float = 1 {
        didSet {
            volume = min(max(volume, 0), 1)
            engine.mainMixerNode.outputVolume = volume
        }
    }

    /// -1...1.
    var balance: Float = 0 {
        didSet {
            balance = min(max(balance, -1), 1)
            playerNode.pan = balance
        }
    }

    /// Where the system default output comes from and how the output unit is bound to it.
    let outputDevices: any OutputDeviceProvider
    /// The device the output unit should use; nil means "whatever the engine chose at creation" (no bind at
    /// the first start, so nothing changes until the default moves). Set by `Player` on a default-output change.
    var outputDevice: AudioDeviceID?

    init(
        volume: Float, balance: Float, eq eqState: EQState = .flat, analyzer: AnalyzerTap = AnalyzerTap(),
        outputDevices: any OutputDeviceProvider = SystemOutputDeviceProvider()
    ) {
        self.analyzer = analyzer
        self.outputDevices = outputDevices
        engine.attach(playerNode)
        engine.attach(eq)
        eq.configureWinampBands()
        eq.apply(eqState)
        // didSet does not run for assignments inside init, so apply explicitly.
        self.volume = min(max(volume, 0), 1)
        self.balance = min(max(balance, -1), 1)
        engine.mainMixerNode.outputVolume = self.volume
        playerNode.pan = self.balance
    }

    /// Connects player -> eq -> mixer at the output rate, stereo, if not already.
    /// Only safe while the engine is stopped: reconnecting an initialized `AVAudioUnitEQ`
    /// at a different rate or channel count throws -10868 (an uncaught Objective-C exception).
    private func connectIfNeeded() {
        let rate = outputSampleRate()
        if let current = processingFormat, current.sampleRate == rate { return }
        guard let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2) else { return }
        engine.connect(playerNode, to: eq, format: format)
        engine.connect(eq, to: engine.mainMixerNode, format: format)
        processingFormat = format
    }

    /// The output node's rate without starting the engine (what `connectIfNeeded` connects at); 44 100 when
    /// it reports none.
    func outputSampleRate() -> Double {
        let rate = engine.outputNode.outputFormat(forBus: 0).sampleRate
        return rate > 0 ? rate : 44_100
    }

    /// Binds the output unit to `outputDevice` before the rate is read. Only called while stopped.
    private func bindOutputDeviceIfNeeded() throws {
        guard let outputDevice else { return }
        if outputDevices.boundDevice(of: engine.outputNode) != outputDevice {
            try outputDevices.bind(outputDevice, to: engine.outputNode)
        }
        let nodeRate = engine.outputNode.outputFormat(forBus: 0).sampleRate
        let info = outputDevices.describe(outputDevice)
        log.info("""
            output bound: device \(outputDevice, privacy: .public) \(info?.name ?? "?", privacy: .public) \
            transport \(info?.transport ?? "?", privacy: .public) nominal \(info?.nominalSampleRate ?? 0, privacy: .public) \
            node rate \(nodeRate, privacy: .public)
            """)
        if let nominal = info?.nominalSampleRate, nominal > 0, nodeRate != nominal {
            log.notice("output node rate \(nodeRate, privacy: .public) differs from the device's nominal \(nominal, privacy: .public)")
        }
    }

    /// Stops the engine if it is running. Never restarts by itself; `Player` decides.
    func stopEngine() {
        if engine.isRunning { engine.stop() }
    }

    func start() throws {
        guard !engine.isRunning else { return }
        try bindOutputDeviceIfNeeded()
        connectIfNeeded()
        if let rate = processingSampleRate {
            log.info("engine starting at processing rate \(rate, privacy: .public)")
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            throw AudioCoreError.engineStart(underlying: error)
        }
        // Remove-then-install is idempotent, so engine restarts (config change) never double-install.
        // The tap does not touch connections; the rate is the processing rate, not the mixer's
        // pre-start report.
        if installsAnalyzer, let rate = processingSampleRate {
            analyzer.install(on: engine.mainMixerNode, sampleRate: rate)
        }
    }
}

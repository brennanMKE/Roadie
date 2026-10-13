import AVFoundation

/// Owns the AVAudioEngine and its nodes: player -> EQ -> main mixer -> output.
@MainActor
final class AudioGraph {
    let engine = AVAudioEngine()
    let playerNode = AVAudioPlayerNode()
    /// Bypassed for now; 0004 configures the bands on this instance.
    let eq = AVAudioUnitEQ(numberOfBands: 10)
    private(set) var connectedFormat: AVAudioFormat?

    var mainMixerNode: AVAudioMixerNode { engine.mainMixerNode }

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

    init(volume: Float, balance: Float) {
        engine.attach(playerNode)
        engine.attach(eq)
        eq.bypass = true
        self.volume = volume
        self.balance = balance
    }

    /// Reconnects player -> eq -> mixer when the sample rate or channel count changes.
    /// Only call while `playerNode` is stopped.
    func connect(format: AVAudioFormat) {
        if let current = connectedFormat,
           current.sampleRate == format.sampleRate,
           current.channelCount == format.channelCount {
            return
        }
        engine.connect(playerNode, to: eq, format: format)
        engine.connect(eq, to: engine.mainMixerNode, format: format)
        connectedFormat = format
    }

    func start() throws {
        guard !engine.isRunning else { return }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            throw AudioCoreError.engineStart(underlying: error)
        }
    }
}

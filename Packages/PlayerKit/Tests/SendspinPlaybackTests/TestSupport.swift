import AVFoundation
import Foundation
import SendspinKit
@testable import AudioCore

/// A scripted Sendspin session: the test pushes events; start, stop and every report are recorded. No network.
actor FakeSendspinSession: SendspinSessionDriving {
    struct Report: Equatable, Sendable { var volume: Int; var muted: Bool }

    private let stream: AsyncStream<SendspinEvent>
    private let continuation: AsyncStream<SendspinEvent>.Continuation
    private(set) var started = 0
    private(set) var stops: [SendspinGoodbyeReason] = []
    private(set) var reports: [Report] = []

    init() {
        (stream, continuation) = AsyncStream.makeStream(bufferingPolicy: .unbounded)
    }

    nonisolated func push(_ event: SendspinEvent) { continuation.yield(event) }

    func events() -> AsyncStream<SendspinEvent> { stream }
    func start() { started += 1 }
    func stop(reason: SendspinGoodbyeReason) { stops.append(reason) }
    func report(volume: Int, muted: Bool) { reports.append(Report(volume: volume, muted: muted)) }
}

/// Records the configurations the player asked sessions for; hands out one fake.
final class FakeSessionFactory: @unchecked Sendable {
    let session = FakeSendspinSession()
    private let lock = NSLock()
    private var _made = 0
    var made: Int { lock.withLock { _made } }

    func make(_ configuration: SendspinConnectionConfiguration) -> any SendspinSessionDriving {
        lock.withLock { _made += 1 }
        return session
    }
}

let testConfiguration = SendspinConnectionConfiguration(
    baseURL: URL(string: "http://sendspin.invalid:8095")!,
    token: "test-token",
    clientID: "test-client",
    name: "Test Mac",
    deviceInfo: SendspinDeviceInfo(softwareVersion: "0"),
    format: SendspinAudioFormat(sampleRate: 44_100)
)

func serverHello(name: String = "Test Server") throws -> SendspinServerHello {
    let json = #"{"server_id":"test-server","name":"\#(name)","version":1,"active_roles":["player@v1"]}"#
    return try JSONDecoder().decode(SendspinServerHello.self, from: Data(json.utf8))
}

let pcm16Stereo44k = SendspinStreamFormat.make(sampleRate: 44_100, channels: 2, bitDepth: 16)

extension SendspinStreamFormat {
    static func make(codec: String = "pcm", sampleRate: Int, channels: Int, bitDepth: Int) -> SendspinStreamFormat {
        let json = #"{"codec":"\#(codec)","sample_rate":\#(sampleRate),"channels":\#(channels),"bit_depth":\#(bitDepth)}"#
        return try! JSONDecoder().decode(SendspinStreamFormat.self, from: Data(json.utf8))
    }
}

/// Little-endian 16-bit stereo sine, the same value on both channels.
func sinePCM16(hz: Double, amplitude: Double, frames: Int, startFrame: Int = 0, rate: Double) -> Data {
    var data = Data(capacity: frames * 4)
    for i in 0..<frames {
        let v = Int16((amplitude * sin(2 * .pi * hz * Double(startFrame + i) / rate) * 32_767).rounded())
        let le = UInt16(bitPattern: v).littleEndian
        for _ in 0..<2 {
            data.append(UInt8(le & 0xff))
            data.append(UInt8(le >> 8))
        }
    }
    return data
}

@MainActor
func waitUntil(timeoutMillis: Int = 5000, _ condition: @MainActor () async -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + .milliseconds(timeoutMillis)
    while ContinuousClock.now < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return await condition()
}

/// A `Player` in offline manual rendering, timed by the render sample clock: nothing opens a device.
@MainActor
final class OfflinePlayer {
    static let rate = 44_100.0
    let player = Player()
    let engine: AVAudioEngine
    let out: AVAudioPCMBuffer

    init() throws {
        let engine = player.ensureGraph().engine
        let format = AVAudioFormat(standardFormatWithSampleRate: Self.rate, channels: 2)!
        try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 512)
        self.engine = engine
        player.streamRenderClock = SampleStreamRenderClock(rate: Self.rate) { engine.manualRenderingSampleTime }
        out = AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat, frameCapacity: 512)!
    }

    /// Renders `blocks` × 512 frames and returns the left channel.
    func renderFrames(blocks: Int) async throws -> [Float] {
        var left: [Float] = []
        for block in 0..<blocks {
            _ = try engine.renderOffline(512, to: out)
            left.append(contentsOf: UnsafeBufferPointer(start: out.floatChannelData![0], count: Int(out.frameLength)))
            if block % 8 == 0 { try await Task.sleep(for: .milliseconds(2)) }
        }
        return left
    }

    static func rms(_ samples: ArraySlice<Float>) -> Float {
        guard !samples.isEmpty else { return 0 }
        return Float((samples.reduce(0.0) { $0 + Double($1 * $1) } / Double(samples.count)).squareRoot())
    }
}

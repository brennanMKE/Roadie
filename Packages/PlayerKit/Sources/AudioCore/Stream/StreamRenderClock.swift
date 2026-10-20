import AVFoundation
import Darwin

/// Maps the player node's render timeline to local time (µs). The seam that lets the stream be tested in
/// offline rendering, where host time is invalid.
protocol StreamRenderClock {
    /// Local µs at which the node sample in `renderTime` reaches the speaker (includes output latency).
    func outputMicros(of renderTime: AVAudioTime, latencySeconds: Double) -> Int64?
    /// The AVAudioTime to pass to `playerNode.play(at:)` so the first scheduled frame is heard at `micros`.
    func startTime(forOutputMicros micros: Int64, latencySeconds: Double, nodeRate: Double) -> AVAudioTime
    func nowMicros() -> Int64
}

/// The real clock: host time (mach_absolute_time, the CLOCK_UPTIME_RAW base).
struct HostStreamRenderClock: StreamRenderClock {
    func outputMicros(of renderTime: AVAudioTime, latencySeconds: Double) -> Int64? {
        guard renderTime.isHostTimeValid else { return nil }
        return Int64(((AVAudioTime.seconds(forHostTime: renderTime.hostTime) + latencySeconds) * 1e6).rounded())
    }

    func startTime(forOutputMicros micros: Int64, latencySeconds: Double, nodeRate: Double) -> AVAudioTime {
        let seconds = max(Double(micros) / 1e6 - latencySeconds, 0)
        return AVAudioTime(hostTime: AVAudioTime.hostTime(forSeconds: seconds))
    }

    func nowMicros() -> Int64 { Self.nowMicros() }

    static func nowMicros() -> Int64 {
        Int64((AVAudioTime.seconds(forHostTime: mach_absolute_time()) * 1e6).rounded())
    }
}

/// Offline manual rendering: the render sample time is the clock. µs = sampleTime / rate × 1e6 + origin.
struct SampleStreamRenderClock: StreamRenderClock {
    let rate: Double
    var originMicros: Int64 = 0
    /// The engine's current render position (`manualRenderingSampleTime`).
    let currentSampleTime: () -> Int64

    func outputMicros(of renderTime: AVAudioTime, latencySeconds: Double) -> Int64? {
        guard renderTime.isSampleTimeValid else { return nil }
        return micros(sample: Double(renderTime.sampleTime)) + Int64((latencySeconds * 1e6).rounded())
    }

    func startTime(forOutputMicros micros: Int64, latencySeconds: Double, nodeRate: Double) -> AVAudioTime {
        let seconds = Double(micros - originMicros) / 1e6 - latencySeconds
        return AVAudioTime(sampleTime: AVAudioFramePosition((max(seconds, 0) * nodeRate).rounded()), atRate: nodeRate)
    }

    func nowMicros() -> Int64 { micros(sample: Double(currentSampleTime())) }

    private func micros(sample: Double) -> Int64 { Int64((sample / rate * 1e6).rounded()) + originMicros }
}

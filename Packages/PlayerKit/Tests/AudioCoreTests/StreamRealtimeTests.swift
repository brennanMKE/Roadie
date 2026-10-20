import AVFoundation
import Foundation
import Testing
@testable import AudioCore

/// Real-time (muted) check that a timed stream holds sync against host time. Opt-in like the other real-time
/// tests: `AUDIOCORE_REALTIME=1`, which only the VM's full tier sets (`--full`).
@MainActor
@Suite(.serialized) struct StreamRealtimeTests {
    @Test(.enabled(if: RealtimeAudio.isAvailable))
    func streamHoldsSyncAgainstHostTimeRealtime() async throws {
        let player = Player()
        player.volume = 0   // silent
        let rate = player.streamOutputSampleRate
        let format = StreamFormat(sampleRate: rate, channels: 2, bitDepth: 16)
        try player.beginStream(format)
        defer { player.endStream() }
        let chunkFrames = Int(rate / 50)   // 20 ms
        let chunkMicros = Int64((Double(chunkFrames) / rate * 1e6).rounded())
        let start = HostStreamRenderClock.nowMicros() + 300_000
        let end = start + 5_000_000
        var index = 0
        var worst: Int64 = 0
        var measured = 0
        while true {
            let now = HostStreamRenderClock.nowMicros()
            if now > end { break }
            // Keep ~400 ms of audio queued ahead, as the server would.
            while start + Int64(index) * chunkMicros < now + 400_000 {
                let pcm = sinePCM16(hz: 441, amplitude: 0.5, frames: chunkFrames,
                                    startFrame: index * chunkFrames, rate: rate)
                player.appendStream(StreamChunk(presentationMicros: start + Int64(index) * chunkMicros, pcm: pcm))
                index += 1
            }
            if now > start + 2_000_000, let error = player.stream?.lastErrorMicros {
                worst = max(worst, abs(error))
                measured += 1
            }
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(player.state == .playing)
        #expect(measured > 10)
        #expect(worst <= 1_000)
        #expect(player.stream?.corrector.snaps == 0)
    }
}

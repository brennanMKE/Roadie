import AVFoundation
import Foundation
import Testing
@testable import AudioCore

/// Real-time (muted) check that a progressive track hands over to a pre-scheduled file. Opt-in like the other
/// real-time tests: `AUDIOCORE_REALTIME=1`, which only the VM's full tier sets (`--full`).
@MainActor
@Suite(.serialized) struct ProgressiveRealtimeTests {
    @Test(.enabled(if: RealtimeAudio.isAvailable))
    func progressiveTrackAdvancesToTheNextFileRealtime() async throws {
        let dir = try ProgressiveFixtures.makeDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let first = try ProgressiveFixtures.wav(in: dir, name: "first.wav", hz: 441)
        let second = try ProgressiveFixtures.wav(in: dir, name: "second.wav", hz: 882)
        let source = TrickleByteSource(data: first.data, available: Int64(first.data.count))
        let player = Player(resolver: TrickleResolver(source: source, wholeFile: first.url))
        player.recordsDiagnostics = true
        let secondTrack = try Track.file(at: second.url)
        player.enqueue([TrickleResolver.progressiveTrack(for: source), secondTrack])
        player.volume = 0   // silent
        player.play()
        #expect(await MixedFormatSupport.waitUntil(timeout: 500) { player.state == .playing })
        #expect(player.usesProgressiveSource)
        #expect(await MixedFormatSupport.waitUntil(timeout: 500) { player.hasPreScheduledNext })

        let deadline = ContinuousClock.now + .seconds(10)
        var indices: [Int] = []
        while ContinuousClock.now < deadline, player.state != .stopped {
            let index = player.queue.currentIndex ?? -1
            if indices.last != index { indices.append(index) }
            try? await Task.sleep(for: .milliseconds(10))
        }
        #expect(player.state == .stopped)
        #expect(player.errorMessage == nil)
        #expect(indices == [0, 1])
        #expect(player.completionDiagnostics == [.advanced(to: secondTrack.id), .reachedEnd])
        #expect(await waitUntil { source.isClosed })
    }
}

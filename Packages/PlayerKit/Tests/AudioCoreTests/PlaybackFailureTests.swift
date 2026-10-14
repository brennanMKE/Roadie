import Foundation
import Testing

@testable import AudioCore

private struct SourceDown: Error, SourceScopedError { let affectsWholeSource = true }

@MainActor @Suite struct PlaybackFailureTests {
    private final class Log {
        var failures: [PlaybackFailure] = []
        var states: [PlaybackState] = []
    }

    private func makePlayer(_ count: Int, honorsCancellation: Bool = true) -> (Player, GateResolver, [Track], Log) {
        let gate = GateResolver(honorsCancellation: honorsCancellation)
        let tracks = makeTracks(count)
        let player = Player(resolver: gate)
        player.enqueue(tracks)
        let log = Log()
        player.addEventObserver { event in
            switch event {
            case .failed(let f): log.failures.append(f)
            case .stateChanged(let s): log.states.append(s)
            default: break
            }
        }
        return (player, gate, tracks, log)
    }

    private func perTrack(_ t: Track) -> AudioCoreError { .unresolvableSource(t.source) }

    @Test func failedTrackIsSkipped() async {
        let (p, gate, t, log) = makePlayer(3)
        p.play(at: 0)
        #expect(await gate.waitForCalls(1))
        await gate.release(t[0].id, with: .failure(perTrack(t[0])))
        #expect(await gate.waitForCalls(2))
        #expect(await gate.calls == [t[0].id, t[1].id])
        #expect(p.state == .loading)
        #expect(p.queue.currentIndex == 1)
        #expect(p.errorMessage == perTrack(t[0]).localizedDescription)
        #expect(log.failures.count == 1)
        #expect(log.failures[0].track?.id == t[0].id)
        #expect(log.failures[0].skipped)
        #expect(log.failures[0].consecutiveFailures == 1)
        #expect(!log.states.contains(.stopped))
        p.stop()
        await gate.releaseAll()
    }

    @Test func skipKeepsThePauseIntent() async {
        let (p, gate, t, _) = makePlayer(2)
        p.play(at: 0)
        p.pause()
        #expect(await gate.waitForCalls(1))
        await gate.release(t[0].id, with: .failure(perTrack(t[0])))
        #expect(await gate.waitForCalls(2))
        #expect(p.state == .loading)
        #expect(!p.autoplayAfterLoad)
        #expect(p.queue.currentIndex == 1)
        p.stop()
        await gate.releaseAll()
    }

    @Test func everyTrackFailingStopsAfterOnePass() async {
        let (p, gate, t, log) = makePlayer(3)
        p.repeatMode = .all
        p.play(at: 0)
        for i in 0..<3 {
            #expect(await gate.waitForCalls(i + 1))
            await gate.release(t[i].id, with: .failure(perTrack(t[i])))
        }
        #expect(await waitUntil { p.state == .stopped })
        try? await Task.sleep(for: .milliseconds(100))
        #expect(await gate.calls.count == 3)
        #expect(log.failures.map(\.skipped) == [true, true, false])
        #expect(log.failures.last?.consecutiveFailures == 3)
        #expect(p.errorMessage != nil)
        #expect(p.queue.currentIndex == 2)
        #expect(p.consecutiveFailures == 0)
    }

    @Test func repeatOneDoesNotRetryAFailedTrack() async {
        let (p, gate, t, log) = makePlayer(2)
        p.repeatMode = .one
        p.play(at: 0)
        #expect(await gate.waitForCalls(1))
        await gate.release(t[0].id, with: .failure(perTrack(t[0])))
        #expect(await waitUntil { p.state == .stopped })
        #expect(await gate.calls.count == 1)
        #expect(log.failures == [
            PlaybackFailure(track: t[0], message: perTrack(t[0]).localizedDescription, consecutiveFailures: 1, skipped: false)
        ])
    }

    @Test func sourceWideFailureStopsAtOnce() async {
        let (p, gate, t, log) = makePlayer(3)
        p.play(at: 0)
        #expect(await gate.waitForCalls(1))
        await gate.release(t[0].id, with: .failure(SourceDown()))
        #expect(await waitUntil { p.state == .stopped })
        #expect(await gate.calls.count == 1)
        #expect(p.queue.currentIndex == 0)
        #expect(log.failures.first?.skipped == false)
    }

    @Test func successResetsTheFailureCount() async throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "pf-\(UUID().uuidString).wav")
        try GaplessRenderTests.writeSine(to: url, hz: 440)
        defer { try? FileManager.default.removeItem(at: url) }
        let (p, gate, t, _) = makePlayer(2)
        try renderSilently(p)
        p.play(at: 0)
        #expect(await gate.waitForCalls(1))
        await gate.release(t[0].id, with: .failure(perTrack(t[0])))
        #expect(await gate.waitForCalls(2))
        #expect(p.consecutiveFailures == 1)
        await gate.release(t[1].id, with: .success(url))
        #expect(await waitUntil { p.state == .playing })
        #expect(p.errorMessage == nil)
        #expect(p.consecutiveFailures == 0)
        p.stop()
    }

    @Test func audioCoreErrorsClassifyBySource() {
        #expect(AudioCoreError.engineStart(underlying: SourceDown()).affectsWholeSource)
        #expect(!AudioCoreError.unresolvableSource(.file(URL(filePath: "/x"))).affectsWholeSource)
    }
}

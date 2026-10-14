import Foundation
import Testing
@testable import AudioCore

@MainActor
@Suite struct PlayerTests {
    @Test func volumeIsClamped() {
        let p = Player()
        p.volume = 1.5
        #expect(p.volume == 1)
        p.volume = -0.5
        #expect(p.volume == 0)
        p.volume = 0.4
        #expect(p.volume == 0.4)
    }

    @Test func repeatToggledIsOffOrAll() {
        #expect(RepeatMode.off.toggled == .all)
        #expect(RepeatMode.all.toggled == .off)
        #expect(RepeatMode.one.toggled == .off)
        let p = Player()
        p.repeatMode = p.repeatMode.toggled
        #expect(p.repeatMode == .all)
        #expect(p.queue.repeatMode == .all)
        p.repeatMode = p.repeatMode.toggled
        #expect(p.repeatMode == .off)
        #expect(p.queue.repeatMode == .off)
    }

    @Test func balanceIsClamped() {
        let p = Player()
        p.balance = 2
        #expect(p.balance == 1)
        p.balance = -2
        #expect(p.balance == -1)
        p.balance = 0.3
        #expect(p.balance == 0.3)
    }

    @Test func repeatedAssignmentDoesNotCrash() {
        let p = Player()
        for i in 0..<1000 {
            p.volume = Float(i % 7) / 3 - 0.5
            p.balance = Float(i % 5) - 2
        }
        #expect((0...1).contains(p.volume))
        #expect((-1...1).contains(p.balance))
    }

    @Test func graphCreatedLaterReceivesClampedValues() {
        let p = Player()
        p.volume = 1.5
        p.balance = -3
        let graph = p.ensureGraph()
        #expect(graph.engine.mainMixerNode.outputVolume == 1)
        #expect(graph.playerNode.pan == -1)
    }

    @Test func existingGraphReceivesClampedValues() {
        let p = Player()
        let graph = p.ensureGraph()
        p.volume = 0.4
        p.balance = 0.3
        #expect(graph.engine.mainMixerNode.outputVolume == 0.4)
        #expect(graph.playerNode.pan == 0.3)
        p.volume = -0.5
        p.balance = 2
        #expect(graph.engine.mainMixerNode.outputVolume == 0)
        #expect(graph.playerNode.pan == 1)
    }
}

/// Removing the current track keeps the transport intent. Offline rendering only (silent, see
/// `renderSilently`); no completions fire, so these cover load/park/resume, not track advance.
@MainActor
@Suite struct RemoveCurrentTrackTests {
    private func makePlayer(_ count: Int, dir: URL) throws -> (Player, [Track]) {
        var tracks: [Track] = []
        for i in 0..<count {
            let url = dir.appending(path: "r\(i).wav")
            try GaplessRenderTests.writeSine(to: url, hz: 440)
            tracks.append(try Track.file(at: url))
        }
        let player = Player()
        player.enqueue(tracks)
        try renderSilently(player)
        return (player, tracks)
    }

    private func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appending(path: "rm-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test func removingCurrentWhilePausedStaysPaused() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let (p, tracks) = try makePlayer(3, dir: dir)
        var events: [String] = []
        p.addEventObserver { event in
            switch event {
            case .trackChanged(let t): events.append("track:\(t?.title ?? "nil")@\(p.currentTime)")
            case .stateChanged(let s): events.append("state:\(s)")
            case .seeked: break
            }
        }
        p.play(at: 0)
        #expect(await waitUntil { p.state == .playing })
        p.pause()
        events.removeAll()
        p.removeTrack(at: 0)
        #expect(p.queue.current?.id == tracks[1].id)
        #expect(events.contains("track:r1@0.0"))
        // Give the parked load time to land; it must not start playback.
        try await Task.sleep(for: .milliseconds(300))
        #expect(p.state == .paused)
        #expect(p.queue.currentIndex == 0)
        #expect(p.currentTime == 0)
        #expect(p.errorMessage == nil)
        #expect(!events.contains("state:playing"))
        p.play()
        #expect(p.state == .playing)
        p.stop()
    }

    @Test func playingBeforeParkedLoadLandsStartsPlayback() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let (p, _) = try makePlayer(2, dir: dir)
        p.play(at: 0)
        #expect(await waitUntil { p.state == .playing })
        p.pause()
        p.removeTrack(at: 0)
        p.play()   // before the parked load lands
        #expect(await waitUntil { p.state == .playing })
        p.stop()
    }

    @Test func removingLastCurrentWhilePausedStops() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let (p, _) = try makePlayer(1, dir: dir)
        p.play(at: 0)
        #expect(await waitUntil { p.state == .playing })
        p.pause()
        p.removeTrack(at: 0)
        #expect(p.state == .stopped)
        #expect(p.queue.current == nil)
        #expect(p.queue.tracks.isEmpty)
    }

    @Test func removingCurrentWhilePlayingPlaysNext() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let (p, tracks) = try makePlayer(3, dir: dir)
        p.play(at: 0)
        #expect(await waitUntil { p.state == .playing })
        p.removeTrack(at: 0)
        #expect(await waitUntil { p.state == .playing && p.queue.current?.id == tracks[1].id })
        #expect(p.currentTime < 0.5)
        p.stop()
    }

    @Test func removingCurrentWhileStoppedDoesNotStart() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let (p, tracks) = try makePlayer(3, dir: dir)
        p.play(at: 0)
        #expect(await waitUntil { p.state == .playing })
        p.stop()
        p.removeTrack(at: 0)
        try await Task.sleep(for: .milliseconds(200))
        #expect(p.state == .stopped)
        #expect(p.queue.current?.id == tracks[1].id)
        #expect(p._graph?.playerNode.isPlaying != true)
    }

    @Test func removingOtherTrackWhilePausedKeepsPosition() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let (p, tracks) = try makePlayer(3, dir: dir)
        p.play(at: 1)
        #expect(await waitUntil { p.state == .playing })
        p.pause()
        let before = p.currentTime
        p.removeTrack(at: 0)
        #expect(p.state == .paused)
        #expect(p.queue.currentIndex == 0)
        #expect(p.queue.current?.id == tracks[1].id)
        #expect(p.currentTime == before)
        p.stop()
    }
}

/// The `.loading` state: a track is selected and its resolve is in flight. A suspending resolver holds
/// the load open; everything is headless and silent (offline rendering where a load completes).
@MainActor
@Suite struct LoadingStateTests {
    private static let missing = URL(filePath: "/nonexistent/skinamp-missing.wav")

    private func makePlayer(_ count: Int = 2, honorsCancellation: Bool = true) -> (Player, GateResolver, [Track]) {
        let gate = GateResolver(honorsCancellation: honorsCancellation)
        let tracks = makeTracks(count)
        let player = Player(resolver: gate)
        player.enqueue(tracks)
        return (player, gate, tracks)
    }

    /// Lets a released load run to its end (it only needs main-actor turns, no engine).
    private func settle() async { try? await Task.sleep(for: .milliseconds(100)) }

    private func wav() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "ld-\(UUID().uuidString).wav")
        try GaplessRenderTests.writeSine(to: url, hz: 440)
        return url
    }

    @Test func playAtIsLoadingSynchronously() async {
        let (p, gate, tracks) = makePlayer()
        p.play(at: 0)
        #expect(p.state == .loading)
        #expect(p.currentTime == 0)
        #expect(p.queue.currentIndex == 0)
        #expect(await gate.waitForCalls(1))
        #expect(await gate.calls == [tracks[0].id])
        p.stop()
        await gate.releaseAll()
    }

    @Test func playFromStoppedIsLoadingSynchronously() async {
        let (p, gate, _) = makePlayer()
        p.play()
        #expect(p.state == .loading)
        #expect(p.autoplayAfterLoad)
        p.stop()
        await gate.releaseAll()
    }

    @Test func repeatedPlayDuringLoadDoesNotRestart() async {
        let (p, gate, _) = makePlayer()
        p.play(at: 0)
        #expect(await gate.waitForCalls(1))
        p.play(); p.play(); p.play()
        p.togglePause(); p.togglePause()
        #expect(p.state == .loading)
        #expect(p.autoplayAfterLoad)
        await settle()
        #expect(await gate.calls.count == 1)
        p.stop()
        await gate.releaseAll()
    }

    @Test func pauseDuringLoadParksIntent() async {
        let (p, gate, _) = makePlayer()
        p.play(at: 0)
        p.pause()
        #expect(p.state == .loading)
        #expect(!p.autoplayAfterLoad)
        p.play()
        #expect(p.autoplayAfterLoad)
        p.togglePause()
        #expect(!p.autoplayAfterLoad)
        #expect(p.state == .loading)
        p.stop()
        await gate.releaseAll()
    }

    @Test func loadLandsPlayingOrParkedPerIntent() async throws {
        let url = try wav()
        defer { try? FileManager.default.removeItem(at: url) }
        for pause in [false, true] {
            let (p, gate, tracks) = makePlayer(1)
            try renderSilently(p)
            p.play(at: 0)
            if pause { p.pause() }
            #expect(await gate.waitForCalls(1))
            await gate.release(tracks[0].id, with: .success(url))
            let expected: PlaybackState = pause ? .paused : .playing
            #expect(await waitUntil { p.state == expected })
            #expect(p.currentTime == 0)
            #expect(p.errorMessage == nil)
            p.stop()
        }
    }

    @Test func newSelectionSupersedesLoad() async {
        let (p, gate, tracks) = makePlayer(honorsCancellation: false)
        p.play(at: 0)
        #expect(await gate.waitForCalls(1))
        p.play(at: 1)
        #expect(p.state == .loading)
        #expect(p.queue.currentIndex == 1)
        #expect(await gate.waitForCalls(2))
        #expect(await gate.calls == [tracks[0].id, tracks[1].id])
        await gate.release(tracks[0].id, with: .success(Self.missing))   // stale: must be ignored
        await settle()
        #expect(p.state == .loading)
        #expect(p.errorMessage == nil)
        await gate.release(tracks[1].id, with: .success(Self.missing))   // live: acted on (open fails)
        #expect(await waitUntil { p.state == .stopped })
        #expect(p.errorMessage != nil)
    }

    @Test func restartingSameTrackSupersedesLoad() async {
        let (p, gate, tracks) = makePlayer(honorsCancellation: false)
        p.play(at: 0)
        #expect(await gate.waitForCalls(1))
        p.previous()   // restarts track 0
        #expect(p.state == .loading)
        #expect(await gate.waitForCalls(2))
        #expect(await gate.calls == [tracks[0].id, tracks[0].id])
        await gate.release(tracks[0].id, with: .success(Self.missing))   // the first load: stale
        await settle()
        #expect(p.state == .loading)
        #expect(p.errorMessage == nil)
        await gate.release(tracks[0].id, with: .success(Self.missing))
        #expect(await waitUntil { p.state == .stopped })
        #expect(p.errorMessage != nil)
    }

    @Test func stopDuringLoadCancels() async {
        let (p, gate, tracks) = makePlayer(honorsCancellation: false)
        p.play(at: 0)
        #expect(await gate.waitForCalls(1))
        p.stop()
        #expect(p.state == .stopped)
        await gate.release(tracks[0].id, with: .success(Self.missing))
        await settle()
        #expect(p.state == .stopped)
        #expect(p.errorMessage == nil)
    }

    @Test func loadFailureStops() async {
        let (p, gate, tracks) = makePlayer()
        p.play(at: 0)
        #expect(await gate.waitForCalls(1))
        await gate.release(tracks[0].id, with: .failure(AudioCoreError.unresolvableSource(tracks[0].source)))
        #expect(await waitUntil { p.state == .stopped })
        #expect(p.errorMessage != nil)
    }

    @Test func removeCurrentWhileLoadingReloadsNext() async {
        let (p, gate, tracks) = makePlayer(3)
        p.play(at: 0)
        #expect(await gate.waitForCalls(1))
        p.removeTrack(at: 0)
        #expect(p.state == .loading)
        #expect(p.queue.current?.id == tracks[1].id)
        #expect(p.autoplayAfterLoad)
        #expect(await gate.waitForCalls(2))
        #expect(await gate.calls == [tracks[0].id, tracks[1].id])
        p.pause()
        p.removeTrack(at: 0)   // current is now tracks[1]
        #expect(p.state == .loading)
        #expect(p.queue.current?.id == tracks[2].id)
        #expect(!p.autoplayAfterLoad)   // the paused intent survives the reload
        p.stop()
        await gate.releaseAll()
    }

    @Test func removeLastCurrentWhileLoadingStops() async {
        let (p, gate, _) = makePlayer(1)
        p.play(at: 0)
        p.removeTrack(at: 0)
        #expect(p.state == .stopped)
        await gate.releaseAll()
    }

    @Test func nextAtEndOfQueueDuringLoadStops() async {
        let (p, gate, tracks) = makePlayer(1, honorsCancellation: false)
        p.play(at: 0)
        #expect(await gate.waitForCalls(1))
        p.next()
        #expect(p.state == .stopped)
        await gate.release(tracks[0].id, with: .success(Self.missing))
        await settle()
        #expect(p.state == .stopped)
        #expect(p.errorMessage == nil)
    }

    @Test func seekDuringLoadIgnoresPreviousFile() async throws {
        let url = try wav()
        defer { try? FileManager.default.removeItem(at: url) }
        let (p, gate, tracks) = makePlayer()
        try renderSilently(p)
        p.play(at: 0)
        #expect(await gate.waitForCalls(1))
        await gate.release(tracks[0].id, with: .success(url))
        #expect(await waitUntil { p.state == .playing })
        var seeks = 0
        p.addEventObserver { if case .seeked = $0 { seeks += 1 } }
        p.play(at: 1)
        #expect(p.state == .loading)
        p.seek(to: 0.5)   // the previous track's file must not be seeked
        #expect(p.currentTime == 0)
        #expect(seeks == 0)
        p.stop()
        await gate.releaseAll()
    }

    @Test func observersSeeLoadingThenPlaying() async throws {
        let url = try wav()
        defer { try? FileManager.default.removeItem(at: url) }
        let (p, gate, tracks) = makePlayer(1)
        try renderSilently(p)
        var states: [PlaybackState] = []
        p.addEventObserver { if case .stateChanged(let s) = $0 { states.append(s) } }
        p.play(at: 0)
        #expect(states == [.loading])
        #expect(await gate.waitForCalls(1))
        await gate.release(tracks[0].id, with: .success(url))
        #expect(await waitUntil { p.state == .playing })
        #expect(states == [.loading, .playing])
        p.stop()
    }
}

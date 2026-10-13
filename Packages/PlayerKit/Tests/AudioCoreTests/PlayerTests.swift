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

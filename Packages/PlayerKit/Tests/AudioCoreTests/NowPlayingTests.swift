import AppKit
import AVFoundation
import Foundation
import MediaPlayer
import Testing
@testable import AudioCore

@Suite struct NowPlayingInfoBuilderTests {
    static let allowedKeys: Set<String> = [
        MPMediaItemPropertyTitle, MPMediaItemPropertyArtist, MPMediaItemPropertyAlbumTitle,
        MPMediaItemPropertyPlaybackDuration, MPNowPlayingInfoPropertyElapsedPlaybackTime,
        MPNowPlayingInfoPropertyPlaybackRate, MPNowPlayingInfoPropertyDefaultPlaybackRate,
        MPNowPlayingInfoPropertyMediaType,
    ]

    func snapshot(
        state: PlaybackState, album: String? = "Album", elapsed: TimeInterval = 12.5
    ) -> NowPlayingSnapshot {
        NowPlayingSnapshot(
            title: "Song", artist: "Artist", album: album, duration: 200, elapsed: elapsed, state: state)
    }

    @Test func playingSnapshotMapsAllFields() {
        let info = NowPlayingInfoBuilder.info(for: snapshot(state: .playing))
        #expect(info[MPMediaItemPropertyTitle] as? String == "Song")
        #expect(info[MPMediaItemPropertyArtist] as? String == "Artist")
        #expect(info[MPMediaItemPropertyAlbumTitle] as? String == "Album")
        #expect(info[MPMediaItemPropertyPlaybackDuration] as? Double == 200)
        #expect(info[MPNowPlayingInfoPropertyElapsedPlaybackTime] as? Double == 12.5)
        #expect(info[MPNowPlayingInfoPropertyPlaybackRate] as? Double == 1)
        #expect(info[MPNowPlayingInfoPropertyDefaultPlaybackRate] as? Double == 1)
        #expect(info[MPNowPlayingInfoPropertyMediaType] as? UInt == MPNowPlayingInfoMediaType.audio.rawValue)
    }

    @Test func pausedAndStoppedHaveZeroRate() {
        for state in [PlaybackState.paused, .stopped] {
            let info = NowPlayingInfoBuilder.info(for: snapshot(state: state))
            #expect(info[MPNowPlayingInfoPropertyPlaybackRate] as? Double == 0)
        }
    }

    @Test func missingAlbumOmitsKey() {
        let info = NowPlayingInfoBuilder.info(for: snapshot(state: .playing, album: nil))
        #expect(info[MPMediaItemPropertyAlbumTitle] == nil)
    }

    @Test func dictionaryHasOnlyDocumentedKeys() {
        let info = NowPlayingInfoBuilder.info(for: snapshot(state: .playing))
        #expect(Set(info.keys).isSubset(of: Self.allowedKeys))
        #expect(info[MPNowPlayingInfoPropertyPlaybackProgress] == nil)
    }
}

@MainActor
final class FakeCommandTarget: NowPlayingCommandTarget {
    var calls: [String] = []
    func play() { calls.append("play") }
    func pause() { calls.append("pause") }
    func togglePlayPause() { calls.append("toggle") }
    func stop() { calls.append("stop") }
    func next() { calls.append("next") }
    func previous() { calls.append("previous") }
    func seek(to seconds: TimeInterval) { calls.append("seek \(seconds)") }
}

@MainActor
@Suite struct NowPlayingBridgeTests {
    @Test func commandsRouteToTarget() {
        let bridge = NowPlayingBridge(player: Player())
        let fake = FakeCommandTarget()
        let commands: [NowPlayingCommand] = [
            .play, .pause, .togglePlayPause, .stop, .next, .previous, .seek(42.5),
        ]
        for command in commands { bridge.perform(command, on: fake) }
        #expect(fake.calls == ["play", "pause", "toggle", "stop", "next", "previous", "seek 42.5"])
    }

    @Test func replacedCommandTargetReceivesCommands() {
        let bridge = NowPlayingBridge(player: Player())
        let fake = FakeCommandTarget()
        bridge.setCommandTarget(fake)
        bridge.perform(.next)
        bridge.perform(.seek(3))
        #expect(fake.calls == ["next", "seek 3.0"])
        bridge.setCommandTarget(nil)
        bridge.perform(.previous)
        #expect(fake.calls == ["next", "seek 3.0"])
    }

    @Test func externalSnapshotOverridesThePlayer() {
        let player = Player()
        let bridge = NowPlayingBridge(player: player, artwork: { _ in nil })
        let external = NowPlayingSnapshot(
            title: "Remote", artist: "Speaker", album: nil, duration: 100, elapsed: 5, state: .playing)
        bridge.showExternal(external, artwork: nil)
        #expect(bridge.isShowingExternal)
        // Player events are ignored while the external snapshot is shown.
        player.stop()
        #expect(bridge.isShowingExternal)
    }

    @Test func clearingExternalReturnsToThePlayer() {
        let bridge = NowPlayingBridge(player: Player(), artwork: { _ in nil })
        bridge.showExternal(nil, artwork: nil)
        #expect(bridge.isShowingExternal)
        bridge.clearExternal()
        #expect(!bridge.isShowingExternal)
    }

    @Test func snapshotIsNilUntilPlayingThenFollowsTrack() async throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "np-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let a = dir.appending(path: "a.wav"), b = dir.appending(path: "b.wav")
        try GaplessRenderTests.writeSine(to: a, hz: 441)
        try GaplessRenderTests.writeSine(to: b, hz: 882)

        let player = Player()
        var first = try Track.file(at: a)
        first.album = "Alb"
        player.enqueue([first, try Track.file(at: b)])
        let bridge = NowPlayingBridge(
            player: player, artwork: { _ in nil },
            infoCenter: .default(), commandCenter: .shared())
        #expect(bridge.currentSnapshot() == nil)

        var events: [String] = []
        player.addEventObserver { event in
            switch event {
            case .trackChanged(let t): events.append("track:\(t?.title ?? "nil")")
            case .stateChanged(let s): events.append("state:\(s)")
            case .seeked: events.append("seeked")
            case .failed: events.append("failed")
            }
        }
        try renderSilently(player)
        player.play()
        #expect(await waitUntil { player.state == .playing })
        let snap = try #require(bridge.currentSnapshot())
        #expect(snap.title == "a" && snap.album == "Alb" && snap.state == .playing)
        #expect(events.contains("track:a"))
        #expect(events.contains("state:playing"))

        player.pause()
        #expect(bridge.currentSnapshot()?.state == .paused)
        player.seek(to: 0.1)
        #expect(events.last != nil)
        player.stop()
        #expect(bridge.currentSnapshot() == nil)
        #expect(events.last == "state:stopped")
    }
}

@MainActor
@Suite struct PlayerEventObserverTests {
    @Test func multipleObserversAndRemoval() {
        let player = Player()
        var first = 0, second = 0
        let t1 = player.addEventObserver { _ in first += 1 }
        let t2 = player.addEventObserver { _ in second += 1 }
        player.stop()   // always emits stateChanged(.stopped)
        #expect(first == 1 && second == 1)
        player.removeEventObserver(t1)
        player.stop()
        #expect(first == 1 && second == 2)
        player.removeEventObserver(t2)
        player.stop()
        #expect(first == 1 && second == 2)
    }
}

/// Tests that install the bridge share the process-wide info center, so they run one at a time.
@MainActor
@Suite(.serialized) struct NowPlayingInfoCenterTests {
    @Test func installedBridgePublishesAndClearsInfoCenter() async throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "np-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appending(path: "tone.wav")
        try GaplessRenderTests.writeSine(to: url, hz: 441)

        let player = Player()
        player.enqueue([try Track.file(at: url)])
        let center = MPNowPlayingInfoCenter.default()
        let bridge = NowPlayingBridge(player: player, artwork: { _ in nil })
        bridge.install()
        defer { bridge.uninstall() }
        try renderSilently(player)
        player.play()
        // The track shows up while loading (paused, rate 0) and flips to playing once it lands.
        #expect(center.nowPlayingInfo?[MPMediaItemPropertyTitle] as? String == "tone")
        #expect(center.nowPlayingInfo?[MPNowPlayingInfoPropertyPlaybackRate] as? Double == 0)
        #expect(await waitUntil { player.state == .playing })
        #expect(center.nowPlayingInfo?[MPNowPlayingInfoPropertyPlaybackRate] as? Double == 1)
        #expect(center.playbackState == .playing)
        player.pause()
        #expect(center.nowPlayingInfo?[MPNowPlayingInfoPropertyPlaybackRate] as? Double == 0)
        #expect(center.playbackState == .paused)
        player.stop()
        #expect(center.nowPlayingInfo == nil)
        #expect(center.playbackState == .stopped)
    }

    /// Real-time run with the mixer muted (opt-in, see `RealtimeAudio`): a gapless auto-advance must
    /// reach the info center. Needs real-time I/O because offline rendering never fires completions.
    @Test(.enabled(if: RealtimeAudio.isAvailable)) func autoAdvanceUpdatesInfoCenterAndAttachesArtwork() async throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "np-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let a = dir.appending(path: "first.wav"), b = dir.appending(path: "second.wav")
        // Long enough that a stale elapsed (the first track's end) cannot pass as "just started".
        try MixedFormatSupport.writeSine(to: a, rate: 44100, channels: 2, seconds: 2, hz: 441)
        try MixedFormatSupport.writeSine(to: b, rate: 44100, channels: 2, seconds: 2, hz: 882)

        let player = Player()
        player.volume = 0
        player.enqueue([try Track.file(at: a), try Track.file(at: b)])
        let center = MPNowPlayingInfoCenter.default()
        let bridge = NowPlayingBridge(player: player, artwork: { _ in nil })
        bridge.install()
        defer { bridge.uninstall(); player.stop() }
        player.play()
        #expect(await waitUntil { center.nowPlayingInfo?[MPMediaItemPropertyTitle] as? String == "first" })
        #expect(await waitUntil { center.nowPlayingInfo?[MPMediaItemPropertyTitle] as? String == "second" })
        let elapsed = center.nowPlayingInfo?[MPNowPlayingInfoPropertyElapsedPlaybackTime] as? Double ?? 99
        #expect(elapsed < 0.5)
    }

    @Test func otherObserversDoNotDisconnectBridge() async throws {
        let player = Player()
        let url = FileManager.default.temporaryDirectory.appending(path: "obs-\(UUID().uuidString).wav")
        try GaplessRenderTests.writeSine(to: url, hz: 441)
        defer { try? FileManager.default.removeItem(at: url) }
        player.enqueue([try Track.file(at: url)])
        let center = MPNowPlayingInfoCenter.default()
        let bridge = NowPlayingBridge(player: player, artwork: { _ in nil })
        bridge.install()
        defer { bridge.uninstall(); player.stop() }
        var seen = 0
        player.addEventObserver { _ in seen += 1 }
        try renderSilently(player)
        player.play()
        #expect(await waitUntil { player.state == .playing })
        #expect(seen > 0)
        let title = url.deletingPathExtension().lastPathComponent
        #expect(await waitUntil { center.nowPlayingInfo?[MPMediaItemPropertyTitle] as? String == title })
    }

    @Test func externalSnapshotPublishesToInfoCenterWithArtwork() throws {
        let player = Player()
        let center = MPNowPlayingInfoCenter.default()
        let bridge = NowPlayingBridge(player: player, artwork: { _ in nil })
        bridge.install()
        defer { bridge.uninstall() }
        let external = NowPlayingSnapshot(
            title: "Remote Song", artist: "Remote Artist", album: "Remote Album", duration: 180, elapsed: 42,
            state: .playing)
        bridge.showExternal(external, artwork: try EmbeddedArtworkTests.pngData())
        #expect(center.nowPlayingInfo?[MPMediaItemPropertyTitle] as? String == "Remote Song")
        #expect(center.nowPlayingInfo?[MPNowPlayingInfoPropertyElapsedPlaybackTime] as? Double == 42)
        #expect(center.nowPlayingInfo?[MPMediaItemPropertyArtwork] != nil)
        #expect(center.playbackState == .playing)
        // A player event while external is shown does not replace it.
        player.stop()
        #expect(center.nowPlayingInfo?[MPMediaItemPropertyTitle] as? String == "Remote Song")
        var paused = external
        paused.state = .paused
        bridge.showExternal(paused, artwork: nil)
        #expect(center.playbackState == .paused)
        bridge.showExternal(nil, artwork: nil)
        #expect(center.nowPlayingInfo == nil)
        bridge.clearExternal()
        #expect(center.nowPlayingInfo == nil)
        #expect(center.playbackState == .stopped)
    }

    /// Artwork attaches to the published info (separate from the timing test so a republish
    /// from the artwork load cannot mask a stale elapsed).
    @Test func artworkAttachesToInfoCenter() async throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "np-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appending(path: "art.wav")
        try GaplessRenderTests.writeSine(to: url, hz: 441)
        let png = try EmbeddedArtworkTests.pngData()
        let player = Player()
        try renderSilently(player)
        player.enqueue([try Track.file(at: url)])
        let center = MPNowPlayingInfoCenter.default()
        let bridge = NowPlayingBridge(player: player, artwork: { _ in png })
        bridge.install()
        defer { bridge.uninstall(); player.stop() }
        player.play()
        #expect(await waitUntil { center.nowPlayingInfo?[MPMediaItemPropertyArtwork] != nil })
    }
}

@MainActor
@Suite struct EmbeddedArtworkTests {
    static func pngData() throws -> Data {
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 8, pixelsHigh: 8, bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0)!
        return try #require(rep.representation(using: .png, properties: [:]))
    }

    /// Converts a generated WAV to m4a with an embedded cover via AVAssetExportSession.
    static func makeM4A(at url: URL, in dir: URL, artwork: Data?) async throws {
        let wav = dir.appending(path: "src.wav")
        try GaplessRenderTests.writeSine(to: wav, hz: 441)
        let session = try #require(AVAssetExportSession(
            asset: AVURLAsset(url: wav), presetName: AVAssetExportPresetAppleM4A))
        if let artwork {
            let item = AVMutableMetadataItem()
            item.identifier = .commonIdentifierArtwork
            item.value = artwork as NSData
            item.dataType = kCMMetadataBaseDataType_PNG as String
            session.metadata = [item]
        }
        try await session.export(to: url, as: .m4a)
    }

    @Test func extractsEmbeddedArtworkFromM4A() async throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "art-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let png = try Self.pngData()
        let url = dir.appending(path: "cover.m4a")
        try await Self.makeM4A(at: url, in: dir, artwork: png)
        let data = try #require(await EmbeddedArtworkLoader.artworkData(for: url))
        #expect(NSImage(data: data) != nil)
    }

    @Test func fileWithoutArtworkReturnsNil() async throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "art-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appending(path: "plain.m4a")
        try await Self.makeM4A(at: url, in: dir, artwork: nil)
        #expect(await EmbeddedArtworkLoader.artworkData(for: url) == nil)
        #expect(await EmbeddedArtworkLoader.artworkData(for: dir.appending(path: "missing.m4a")) == nil)
    }
}

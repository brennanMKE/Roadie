import AVFoundation
import Foundation
import PlexKit
import Testing
@testable import AudioCore
@testable import TrackCache

/// Manual rendering must be on before the first `play`, so no output device opens.
@MainActor
private func renderSilently(_ player: Player) throws {
    let engine = player.ensureGraph().engine
    let format = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 2)!
    try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 512)
}

/// Polls a main-actor condition (up to `timeout` seconds) without fixed sleeps in the happy path.
@MainActor
private func pollMain(timeout: TimeInterval = 5, _ condition: @MainActor () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return condition()
}

/// 0.2 s of 44.1 kHz stereo 16-bit silence as WAV bytes.
private func silentWAV(in dir: URL) throws -> Data {
    let url = dir.appendingPathComponent("silence.wav")
    let settings: [String: Any] = [
        AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 44100.0, AVNumberOfChannelsKey: 2,
        AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false,
    ]
    do {
        let file = try AVAudioFile(forWriting: url, settings: settings)
        let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 8820)!
        buffer.frameLength = 8820
        try file.write(from: buffer)
    }
    return try Data(contentsOf: url)
}

@MainActor
struct PlexPlaybackBufferingTests {
    private let partKey = "/library/parts/5010/1791856627/file.wav"

    @MainActor
    private struct Fixture {
        let h = Harness()
        let player: Player
        let track: Track
        let cacheKey: String
        let size: Int64
        let partKey: String
        let states: StateLog

        init(partKey: String) throws {
            self.partKey = partKey
            player = Player(resolver: PlexTrackResolver(cache: h.cache, savedMachineIdentifier: { fixtureMachineIdentifier }))
            try renderSilently(player)
            // Outside the cache directory, which would adopt the file as an entry.
            let scratch = makeTempDir()
            defer { try? FileManager.default.removeItem(at: scratch) }
            let wav = try silentWAV(in: scratch)
            size = Int64(wav.count)
            var plexTrack = try fixtureTrack()
            plexTrack.media[0].parts[0].key = partKey
            plexTrack.media[0].parts[0].size = Int(size)
            track = try Track(plexTrack: plexTrack, machineIdentifier: fixtureMachineIdentifier)
            guard case .plex(_, let key, _) = track.source else { throw TrackCacheError.notPlexTrack }
            cacheKey = key
            h.stub.setBody(wav, for: partKey)
            let log = StateLog()
            states = log
            player.addEventObserver { event in
                if case .stateChanged(let state) = event { log.states.append(state) }
            }
        }

        func finish() {
            player.stop()
            h.cleanup()
        }
    }

    @MainActor
    final class StateLog { var states: [PlaybackState] = [] }

    @Test func uncachedTrackIsLoadingUntilTheDownloadLands() async throws {
        let f = try Fixture(partKey: partKey); defer { f.finish() }
        f.h.stub.gate(partKey)
        f.player.enqueue([f.track])
        f.player.play()
        #expect(f.player.state == .loading)
        #expect(await pollMain { f.h.stub.calls(partKey) == 1 })
        #expect(f.player.state == .loading)
        f.h.stub.release(partKey)
        #expect(await pollMain { f.player.state == .playing })
        #expect(f.states.states == [.loading, .playing])
        #expect(f.player.errorMessage == nil)
        let entries = await f.h.cache.entries()
        #expect(entries.count == 1, "entries: \(entries.count)")
    }

    @Test func cachedTrackStartsWithoutADownload() async throws {
        let f = try Fixture(partKey: partKey); defer { f.finish() }
        _ = try await f.h.cache.file(forKey: f.cacheKey, partKey: partKey, expectedSize: f.size)
        #expect(f.h.stub.calls(partKey) == 1)
        f.player.enqueue([f.track])
        f.player.play()
        #expect(await pollMain { f.player.state == .playing })
        #expect(f.h.stub.calls(partKey) == 1)
        #expect(f.states.states == [.loading, .playing])
    }

    @Test func aFailedDownloadStopsWithTheCacheMessage() async throws {
        let f = try Fixture(partKey: partKey); defer { f.finish() }
        f.h.stub.gate(partKey)
        f.player.enqueue([f.track])
        f.player.play()
        #expect(await pollMain { f.h.stub.calls(partKey) == 1 })
        let failure = TrackCacheError.download(.notFound)
        f.h.stub.fail(partKey, with: failure)
        #expect(await pollMain { f.player.state == .stopped })
        #expect(f.player.errorMessage == failure.errorDescription)
        #expect(f.states.states == [.loading, .stopped])
    }
}

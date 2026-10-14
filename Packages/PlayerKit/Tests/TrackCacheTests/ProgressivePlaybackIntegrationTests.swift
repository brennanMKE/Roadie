import AVFoundation
import Foundation
import PlexKit
import Testing
@testable import AudioCore
@testable import TrackCache

/// A Plex track through the real cache and the real `Player` (offline rendering): it starts while the download
/// is still arriving, and the finished file in the cache is the one that was downloaded.
@MainActor
struct ProgressivePlaybackIntegrationTests {
    static let partKey = "/library/parts/5010/1791856627/file.wav"
    static let chunks = 8
    /// Long enough that CoreAudio's 64 KB read-ahead is a small part of the file.
    static let frames = 132_300
    static let firstChunks = 5

    /// 3 s of 440 Hz, 16-bit stereo, as WAV bytes.
    static func sineWAV(in dir: URL) throws -> Data {
        let url = dir.appendingPathComponent("sine.wav")
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 44100.0, AVNumberOfChannelsKey: 2,
            AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false,
        ]
        do {
            let file = try AVAudioFile(forWriting: url, settings: settings)
            let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(Self.frames))!
            buffer.frameLength = AVAudioFrameCount(Self.frames)
            for ch in 0..<2 {
                for i in 0..<Self.frames { buffer.floatChannelData![ch][i] = Float(0.5 * sin(2 * .pi * 440 * Double(i) / 44100)) }
            }
            try file.write(from: buffer)
        }
        return try Data(contentsOf: url)
    }

    @MainActor
    struct Fixture {
        let h = Harness()
        let player: Player
        let track: Track
        let cacheKey: String
        let body: Data
        let engine: AVAudioEngine
        let out: AVAudioPCMBuffer

        init() throws {
            let scratch = makeTempDir()
            defer { try? FileManager.default.removeItem(at: scratch) }
            body = try ProgressivePlaybackIntegrationTests.sineWAV(in: scratch)
            var plexTrack = try fixtureTrack()
            plexTrack.media[0].parts[0].key = ProgressivePlaybackIntegrationTests.partKey
            plexTrack.media[0].parts[0].size = body.count
            track = try Track(plexTrack: plexTrack, machineIdentifier: fixtureMachineIdentifier)
            guard case .plex(_, let key, _) = track.source else { throw TrackCacheError.notPlexTrack }
            cacheKey = key
            player = Player(resolver: PlexTrackResolver(cache: h.cache, savedMachineIdentifier: { fixtureMachineIdentifier }))
            var policy = ProgressiveReadPolicy()
            policy.minimumPrerollBytes = 8192
            policy.prerollSeconds = 0.01
            player.progressivePolicy = policy
            engine = player.ensureGraph().engine
            try engine.enableManualRenderingMode(
                .offline, format: AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 2)!, maximumFrameCount: 512)
            out = AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat, frameCapacity: 512)!
            h.stub.setBody(body, for: ProgressivePlaybackIntegrationTests.partKey)
            h.stub.trickle(ProgressivePlaybackIntegrationTests.partKey, chunkSize: (body.count + Self.chunkCount - 1) / Self.chunkCount)
        }

        static var chunkCount: Int { ProgressivePlaybackIntegrationTests.chunks }

        func finish() {
            player.stop()
            h.cleanup()
        }

        func release(_ count: Int) { h.stub.releaseChunks(ProgressivePlaybackIntegrationTests.partKey, count: count) }

        /// Renders until the last buffer is queued and drained; returns the audible frames.
        func renderToEnd() async throws -> Int {
            var audible = 0
            var rendered = 0
            let deadline = ContinuousClock.now + .seconds(15)
            while ContinuousClock.now < deadline {
                guard let feeder = player.progressive?.feeder else { break }
                if rendered < Int(feeder.framesScheduled) {
                    _ = try engine.renderOffline(512, to: out)
                    rendered += 512
                    var peak: Float = 0
                    for i in 0..<Int(out.frameLength) { peak = max(peak, abs(out.floatChannelData![0][i])) }
                    if peak > 0.01 { audible += 512 }
                } else if feeder.hasScheduledLastBuffer {
                    break
                } else {
                    try await Task.sleep(for: .milliseconds(2))
                }
            }
            return audible
        }
    }

    @Test func aPlexTrackStartsBeforeItsDownloadCompletesAndIsCachedIntact() async throws {
        let f = try Fixture(); defer { f.finish() }
        f.player.enqueue([f.track])
        f.release(Self.firstChunks)
        f.player.play()
        #expect(await waitUntil { f.player.state == .playing })
        #expect(f.h.stub.releasedChunks(Self.partKey) < Self.chunks)   // playing while the download is unfinished
        #expect(f.player.usesProgressiveSource)
        f.release(Self.chunks - Self.firstChunks)
        let settled1 = await eventually { await f.h.cache.entries().count == 1 }
        #expect(settled1)
        let audible = try await f.renderToEnd()
        #expect(audible >= Self.frames - 1024 && audible <= Self.frames + 1024, "audible frames \(audible)")

        let entry = try #require(await f.h.cache.entries().first)
        #expect(entry.size == Int64(f.body.count))
        let cached = f.h.dir.appendingPathComponent(entry.fileName)
        #expect(try Data(contentsOf: cached) == f.body)
        #expect(tempContents(f.h.dir).isEmpty)
    }

    @Test func theCurrentTrackStaysPinnedWhileItStreams() async throws {
        let f = try Fixture(); defer { f.finish() }
        await f.h.cache.setPinned([f.cacheKey])
        f.player.enqueue([f.track])
        f.release(Self.firstChunks)
        f.player.play()
        #expect(await waitUntil { f.player.state == .playing })
        f.player.stop()
        // The reader let go, but the pinned download carries on and is verified and indexed.
        f.release(Self.chunks)
        let settled2 = await eventually { await f.h.cache.entries().count == 1 }
        #expect(settled2)
        #expect(f.h.stub.cancelCount == 0)
        #expect(tempContents(f.h.dir).isEmpty)
    }

    @Test func skippingAwayWithoutAPinnerCancelsTheDownload() async throws {
        let f = try Fixture(); defer { f.finish() }
        f.player.enqueue([f.track])
        f.release(Self.firstChunks)
        f.player.play()
        #expect(await waitUntil { f.player.state == .playing })
        f.player.stop()
        #expect(await eventually { f.h.stub.cancelCount == 1 })
        let settled3 = await eventually { await f.h.cache.stats().inFlight == 0 }
        #expect(settled3)
        #expect(await f.h.cache.entries().isEmpty)
        #expect(tempContents(f.h.dir).isEmpty)
    }
}

/// Polls a main-actor condition (up to 5 s).
@MainActor
private func eventually(_ condition: @MainActor () async -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + .seconds(5)
    while ContinuousClock.now < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return await condition()
}

/// Polls a main-actor condition (up to 5 s).
@MainActor
private func waitUntil(_ condition: @MainActor () -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + .seconds(5)
    while ContinuousClock.now < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return condition()
}

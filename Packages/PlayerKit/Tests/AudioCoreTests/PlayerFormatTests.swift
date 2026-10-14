import Foundation
import Testing
@testable import AudioCore

/// `Player.currentFormat` follows the opened file. Offline rendering only: silent.
@MainActor
@Suite struct PlayerFormatTests {
    @Test func currentFormatFollowsLoadedFile() async throws {
        let dir = try MixedFormatSupport.makeDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appending(path: "mono.wav")
        try MixedFormatSupport.writeSine(to: url, rate: 22050, channels: 1, seconds: 1)
        let p = Player()
        p.enqueue([try Track.file(at: url)])
        try renderSilently(p)
        #expect(p.currentFormat == nil)
        p.play()
        #expect(await waitUntil { p.state == .playing })
        #expect(p.currentFormat == PlaybackFormat(sampleRate: 22050, channels: 1))
        p.stop()
        #expect(p.currentFormat == nil)
    }

    @Test func currentFormatIsNilWhileLoading() async throws {
        let dir = try MixedFormatSupport.makeDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appending(path: "stereo.wav")
        try MixedFormatSupport.writeSine(to: url, rate: 48000, channels: 2, seconds: 1)
        let gate = GateResolver()
        let tracks = makeTracks(1)
        let p = Player(resolver: gate)
        p.enqueue(tracks)
        try renderSilently(p)
        p.play(at: 0)
        #expect(p.state == .loading)
        #expect(p.currentFormat == nil)
        #expect(await gate.waitForCalls(1))
        await gate.release(tracks[0].id, with: .success(url))
        #expect(await waitUntil { p.state == .playing })
        #expect(p.currentFormat == PlaybackFormat(sampleRate: 48000, channels: 2))
        p.stop()
    }
}

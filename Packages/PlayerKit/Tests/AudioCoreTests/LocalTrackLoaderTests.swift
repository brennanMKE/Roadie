import AVFoundation
import Foundation
import Testing
@testable import AudioCore

private func makeTempDir() throws -> URL {
    let dir = FileManager.default.temporaryDirectory.appending(path: "LocalTrackLoaderTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

private func writeWAV(to url: URL, seconds: Double, sampleRate: Double = 44_100, channels: Int = 2) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    let settings: [String: Any] = [
        AVFormatIDKey: kAudioFormatLinearPCM,
        AVSampleRateKey: sampleRate,
        AVNumberOfChannelsKey: channels,
        AVLinearPCMBitDepthKey: 16,
    ]
    let frames = AVAudioFrameCount(seconds * sampleRate)
    let file = try AVAudioFile(forWriting: url, settings: settings)
    let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frames)!
    buffer.frameLength = frames
    for channel in 0..<channels {
        let data = buffer.floatChannelData![channel]
        for i in 0..<Int(frames) {
            data[i] = 0.1 * Float(sin(2 * Double.pi * 440 * Double(i) / sampleRate))
        }
    }
    try file.write(from: buffer)
}

@Suite struct LocalTrackLoaderTests {
    @Test func wavYieldsTrackWithFormatAndFallbackTitle() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appending(path: "01 Intro.wav")
        try writeWAV(to: url, seconds: 3, sampleRate: 48_000, channels: 2)

        let result = await LocalTrackLoader.load([url])
        #expect(result.skipped.isEmpty)
        let track = try #require(result.tracks.first)
        #expect(result.tracks.count == 1)
        #expect(track.title == "01 Intro")
        #expect(track.artist == "")
        #expect(abs(track.duration - 3) < 0.05)
        #expect(track.sampleRate == 48_000)
        #expect(track.channels == 2)
        let bitrate = try #require(track.bitrate)
        #expect(abs(Double(bitrate) - 1536) < 154)
        #expect(track.source == .file(url))
    }

    @Test func foldersAreWalkedRecursivelyInFinderOrder() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let album = dir.appending(path: "Album")
        let expected = [
            album.appending(path: "01 One.wav"),
            album.appending(path: "2 Two.wav"),
            album.appending(path: "10 Ten.wav"),
            album.appending(path: "Disc 2/01 Eleven.wav"),
        ]
        for url in expected.reversed() { try writeWAV(to: url, seconds: 0.2) }
        try Data("art".utf8).write(to: album.appending(path: "cover.txt"))

        // /var vs /private/var differs between the two spellings, so compare below the temp dir.
        let relative = LocalTrackLoader.collectAudioURLs(from: [album]).map { $0.path.components(separatedBy: "/Album/").last }
        #expect(relative == ["01 One.wav", "2 Two.wav", "10 Ten.wav", "Disc 2/01 Eleven.wav"])
        let result = await LocalTrackLoader.load([album])
        #expect(result.tracks.count == 4)
        #expect(result.skipped.isEmpty)
        #expect(result.tracks.map(\.title) == ["01 One", "2 Two", "10 Ten", "01 Eleven"])
    }

    @Test func bogusMP3IsSkippedNotCrashed() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let good = dir.appending(path: "good.wav")
        let junk = dir.appending(path: "junk.mp3")
        let missing = dir.appending(path: "missing.wav")
        try writeWAV(to: good, seconds: 0.2)
        try Data("this is not audio".utf8).write(to: junk)

        let result = await LocalTrackLoader.load([good, junk, missing])
        #expect(result.tracks.count == 1)
        #expect(result.skipped.count == 2)
        #expect(result.skipped[0].url.lastPathComponent == "junk.mp3")
        #expect(!result.skipped[0].reason.isEmpty)
        #expect(result.skipped[1].url.lastPathComponent == "missing.wav")
    }

    @Test func explicitNonAudioFileIsReportedSkipped() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let notes = dir.appending(path: "notes.txt")
        try Data("hello".utf8).write(to: notes)

        let result = await LocalTrackLoader.load([notes])
        #expect(result.skipped.count == 1)
        #expect(result.tracks.isEmpty)
    }

    @Test func hiddenFilesAndEmptyFoldersAreIgnored() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let folder = dir.appending(path: "Folder")
        try FileManager.default.createDirectory(at: folder.appending(path: "Empty"), withIntermediateDirectories: true)
        try Data("junk".utf8).write(to: folder.appending(path: "._01.wav"))
        try Data("junk".utf8).write(to: folder.appending(path: ".hidden.wav"))

        let result = await LocalTrackLoader.load([folder])
        #expect(result.tracks.isEmpty)
        #expect(result.skipped.isEmpty)
    }

    @Test func inputOrderIsPreserved() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let urls = ["a", "b", "c", "d", "e", "f"].map { dir.appending(path: "\($0).wav") }
        for (i, url) in urls.enumerated() { try writeWAV(to: url, seconds: 0.1 + Double(i) * 0.3) }
        let order = [urls[2], urls[0], urls[5], urls[1], urls[4], urls[3]]

        let result = await LocalTrackLoader.load(order)
        #expect(result.tracks.map(\.source) == order.map { .file($0) })
    }

    @Test func embeddedTitleAndArtistAreRead() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let wav = dir.appending(path: "src.wav")
        let m4a = dir.appending(path: "tagged.m4a")
        try writeWAV(to: wav, seconds: 1)

        let title = AVMutableMetadataItem()
        title.identifier = .commonIdentifierTitle
        title.value = "Tagged Title" as NSString
        title.extendedLanguageTag = "und"
        let artist = AVMutableMetadataItem()
        artist.identifier = .commonIdentifierArtist
        artist.value = "Tagged Artist" as NSString
        artist.extendedLanguageTag = "und"

        let session = try #require(AVAssetExportSession(asset: AVURLAsset(url: wav), presetName: AVAssetExportPresetAppleM4A))
        session.metadata = [title, artist]
        try await session.export(to: m4a, as: .m4a)

        let track = try await LocalTrackLoader.loadTrack(at: m4a)
        #expect(track.title == "Tagged Title")
        #expect(track.artist == "Tagged Artist")
    }
}

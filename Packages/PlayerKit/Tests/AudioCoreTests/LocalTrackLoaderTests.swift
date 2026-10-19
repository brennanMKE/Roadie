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
    @Test func playlistExpandsInOrderWithMissingFilesSkipped() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try writeWAV(to: dir.appending(path: "one.wav"), seconds: 0.2)
        try writeWAV(to: dir.appending(path: "sub/two.wav"), seconds: 0.2)
        let list = dir.appending(path: "list.m3u8")
        try Data("#EXTM3U\n#EXTINF:1,X - One\none.wav\nmissing.wav\nsub/two.wav\n".utf8).write(to: list)

        let result = await LocalTrackLoader.load([list])
        #expect(result.tracks.map(\.title) == ["one", "two"])
        #expect(result.skipped.map(\.reason) == ["file not found"])
    }

    @Test func playlistEntriesKeepInputPosition() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        for name in ["a", "b", "c", "d"] { try writeWAV(to: dir.appending(path: "\(name).wav"), seconds: 0.2) }
        let list = dir.appending(path: "list.pls")
        try Data("[playlist]\nFile1=b.wav\nFile2=c.wav\nNumberOfEntries=2\n".utf8).write(to: list)

        let result = await LocalTrackLoader.load([dir.appending(path: "a.wav"), list, dir.appending(path: "d.wav")])
        #expect(result.tracks.map(\.title) == ["a", "b", "c", "d"])
        #expect(result.skipped.isEmpty)
    }

    @Test func nestedPlaylistExpandsInPlaceRelativeToItsFolder() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        for path in ["a.wav", "c.wav", "sub/b.wav"] { try writeWAV(to: dir.appending(path: path), seconds: 0.2) }
        try Data("b.wav\n".utf8).write(to: dir.appending(path: "sub/inner.m3u"))
        let top = dir.appending(path: "top.m3u8")
        try Data("a.wav\nsub/inner.m3u\nc.wav\n".utf8).write(to: top)

        let result = await LocalTrackLoader.load([top])
        #expect(result.tracks.map(\.title) == ["a", "b", "c"])
        #expect(result.skipped.isEmpty)
    }

    @Test func twoLevelNestingMixesFormats() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try writeWAV(to: dir.appending(path: "one.wav"), seconds: 0.2)
        try writeWAV(to: dir.appending(path: "l1/two.wav"), seconds: 0.2)
        try writeWAV(to: dir.appending(path: "l1/l2/three.wav"), seconds: 0.2)
        try Data("three.wav\n".utf8).write(to: dir.appending(path: "l1/l2/deep.m3u"))
        try Data("[playlist]\nFile1=two.wav\nFile2=l2/deep.m3u\nNumberOfEntries=2\n".utf8)
            .write(to: dir.appending(path: "l1/mid.pls"))
        let top = dir.appending(path: "top.m3u")
        try Data("one.wav\nl1/mid.pls\n".utf8).write(to: top)

        let result = await LocalTrackLoader.load([top])
        #expect(result.tracks.map(\.title) == ["one", "two", "three"])
        #expect(result.skipped.isEmpty)
    }

    @Test func playlistCycleIsSkipped() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        for name in ["x", "y"] { try writeWAV(to: dir.appending(path: "\(name).wav"), seconds: 0.2) }
        try Data("x.wav\nb.m3u\n".utf8).write(to: dir.appending(path: "a.m3u"))
        try Data("y.wav\na.m3u\n".utf8).write(to: dir.appending(path: "b.m3u"))

        let result = await LocalTrackLoader.load([dir.appending(path: "a.m3u")])
        #expect(result.tracks.map(\.title) == ["x", "y"])
        #expect(result.skipped.map(\.reason) == ["playlist cycle"])
    }

    @Test func selfReferencingPlaylistIsSkipped() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        for name in ["x", "y"] { try writeWAV(to: dir.appending(path: "\(name).wav"), seconds: 0.2) }
        let list = dir.appending(path: "self.m3u")
        try Data("x.wav\nself.m3u\ny.wav\n".utf8).write(to: list)

        let result = await LocalTrackLoader.load([list])
        #expect(result.tracks.map(\.title) == ["x", "y"])
        #expect(result.skipped.map(\.reason) == ["playlist cycle"])
    }

    @Test func missingNestedPlaylistIsSkipped() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        for name in ["x", "y"] { try writeWAV(to: dir.appending(path: "\(name).wav"), seconds: 0.2) }
        let top = dir.appending(path: "top.m3u")
        try Data("x.wav\ngone.m3u\ny.wav\n".utf8).write(to: top)

        let result = await LocalTrackLoader.load([top])
        #expect(result.tracks.map(\.title) == ["x", "y"])
        #expect(result.skipped.map(\.reason) == ["could not read playlist"])
    }

    @Test func nestingDeeperThanEightLevelsIsSkipped() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        for n in 1...9 {
            try writeWAV(to: dir.appending(path: "t\(n).wav"), seconds: 0.2)
            let body = n < 9 ? "t\(n).wav\np\(n + 1).m3u\n" : "t\(n).wav\n"
            try Data(body.utf8).write(to: dir.appending(path: "p\(n).m3u"))
        }

        let result = await LocalTrackLoader.load([dir.appending(path: "p1.m3u")])
        #expect(result.tracks.map(\.title) == (1...8).map { "t\($0)" })
        #expect(result.skipped.map(\.reason) == ["playlists nested too deeply"])
    }

    @Test func unreadablePlaylistIsReportedSkipped() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let result = await LocalTrackLoader.load([dir.appending(path: "nope.m3u")])
        #expect(result.tracks.isEmpty)
        #expect(result.skipped.map(\.reason) == ["could not read playlist"])
    }

    @Test func folderWalkIgnoresPlaylistFiles() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try writeWAV(to: dir.appending(path: "x.wav"), seconds: 0.2)
        try Data("x.wav\n".utf8).write(to: dir.appending(path: "x.m3u"))
        try Data("[playlist]\nFile1=x.wav\n".utf8).write(to: dir.appending(path: "x.pls"))

        let result = await LocalTrackLoader.load([dir])
        #expect(result.tracks.count == 1)
        #expect(result.skipped.isEmpty)
    }

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

        let album = AVMutableMetadataItem()
        album.identifier = .commonIdentifierAlbumName
        album.value = "Tagged Album" as NSString
        album.extendedLanguageTag = "und"

        let session = try #require(AVAssetExportSession(asset: AVURLAsset(url: wav), presetName: AVAssetExportPresetAppleM4A))
        session.metadata = [title, artist, album]
        try await session.export(to: m4a, as: .m4a)

        let track = try await LocalTrackLoader.loadTrack(at: m4a)
        #expect(track.title == "Tagged Title")
        #expect(track.artist == "Tagged Artist")
        #expect(track.album == "Tagged Album")
    }
}

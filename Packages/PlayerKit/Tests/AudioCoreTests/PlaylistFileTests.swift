import Foundation
import Testing
@testable import AudioCore

private let listURL = URL(filePath: "/tmp/x/list.m3u")

private func fileTrack(_ path: String, title: String, artist: String = "", duration: TimeInterval = 0) -> Track {
    Track(title: title, artist: artist, duration: duration, source: .file(URL(filePath: path)))
}

private func paths(_ entries: [PlaylistFile.Entry], relativeTo url: URL = listURL) -> [String] {
    entries.compactMap {
        if case .file(let file) = PlaylistFile.resolve($0, relativeTo: url) { return file.path }
        return nil
    }
}

@Suite struct PlaylistFileTests {
    @Test func parsesExtendedM3UWithEXTINF() {
        let text = "#EXTM3U\n#EXTINF:241,Artist - Title\na.mp3\n#EXTINF:-1,Stream Thing\nb.mp3\nc.mp3\n"
        let entries = PlaylistFile.parse(Data(text.utf8), format: .m3u)
        #expect(entries == [
            .init(location: "a.mp3", title: "Artist - Title", duration: 241),
            .init(location: "b.mp3", title: "Stream Thing", duration: nil),
            .init(location: "c.mp3"),
        ])
    }

    @Test func parsesPlainM3USkippingCommentsAndBlankLines() {
        let text = "# a comment\n\n  one.mp3  \n#another\n\ntwo.flac\n"
        #expect(PlaylistFile.parse(Data(text.utf8), format: .m3u).map(\.location) == ["one.mp3", "two.flac"])
    }

    @Test func acceptsCRLFAndCRLineEndings() {
        #expect(PlaylistFile.parse(Data("a.mp3\r\nb.mp3\r\n".utf8), format: .m3u).map(\.location) == ["a.mp3", "b.mp3"])
        #expect(PlaylistFile.parse(Data("a.mp3\rb.mp3\r".utf8), format: .m3u).map(\.location) == ["a.mp3", "b.mp3"])
    }

    @Test func stripsUTF8BOM() {
        let data = Data([0xEF, 0xBB, 0xBF]) + Data("#EXTM3U\na.mp3\n".utf8)
        #expect(PlaylistFile.parse(data, format: .m3u).map(\.location) == ["a.mp3"])
    }

    @Test func m3u8DecodesUTF8() {
        let text = "#EXTM3U\n#EXTINF:200,Björk - Hunter\nBjörk/Homogenic/01 Hunter.mp3\n"
        let entries = PlaylistFile.parse(Data(text.utf8), format: .m3u, pathExtension: "m3u8")
        #expect(entries == [.init(location: "Björk/Homogenic/01 Hunter.mp3", title: "Björk - Hunter", duration: 200)])
    }

    @Test func m3uFallsBackToWindows1252() {
        let data = Data("Caf".utf8) + Data([0xE9]) + Data(".mp3\n".utf8)
        #expect(PlaylistFile.parse(data, format: .m3u, pathExtension: "m3u").map(\.location) == ["Café.mp3"])
    }

    @Test func parsesPLSOrderedByNumberIgnoringCountAndCase() {
        let text = """
        [playlist]
        File3=c.mp3
        Title3=Cee
        file2=b.mp3
        File1=a.mp3
        Length1=10
        Length2=-1
        Title4=orphan
        NumberOfEntries=9
        Version=2
        """
        let entries = PlaylistFile.parse(Data(text.utf8), format: .pls)
        #expect(entries == [
            .init(location: "a.mp3", title: nil, duration: 10),
            .init(location: "b.mp3"),
            .init(location: "c.mp3", title: "Cee"),
        ])
    }

    @Test func plsContentDetectedWhateverTheExtension() {
        let data = Data("\n[Playlist]\nFile1=a.mp3\n".utf8)
        #expect(PlaylistFile.format(for: listURL, data: data) == .pls)
        #expect(PlaylistFile.format(for: listURL, data: Data("a.mp3\n".utf8)) == .m3u)
        #expect(PlaylistFile.format(for: URL(filePath: "/tmp/x/l.pls"), data: Data()) == .pls)
    }

    @Test func resolvesRelativeAbsoluteFileURLAndBackslashPaths() {
        let entries = ["sub/a.mp3", "../b.mp3", "/abs/c.mp3", "file:///abs/d%20e.mp3", "Artist\\Album\\01.mp3"]
            .map { PlaylistFile.Entry(location: $0) }
        #expect(paths(entries) == [
            "/tmp/x/sub/a.mp3", "/tmp/b.mp3", "/abs/c.mp3", "/abs/d e.mp3", "/tmp/x/Artist/Album/01.mp3",
        ])
    }

    @Test func skipsStreamsAndResolvesNestedPlaylists() {
        #expect(PlaylistFile.resolve(.init(location: "http://radio.example/stream"), relativeTo: listURL)
            == .skip(location: "http://radio.example/stream", reason: "streams are not supported"))
        #expect(PlaylistFile.resolve(.init(location: "other.pls"), relativeTo: listURL)
            == .file(URL(filePath: "/tmp/x/other.pls")))
    }

    @Test func serializesExtendedM3U() {
        let tracks = [
            fileTrack("/tmp/x/sub/a.mp3", title: "Title", artist: "Artist", duration: 240.6),
            fileTrack("/music/b.mp3", title: "Bee"),
        ]
        let out = PlaylistFile.serialize(tracks, format: .m3u, playlistURL: listURL)
        #expect(String(decoding: out.data, as: UTF8.self)
            == "#EXTM3U\n#EXTINF:241,Artist - Title\nsub/a.mp3\n#EXTINF:-1,Bee\n/music/b.mp3\n")
        #expect(out.written == 2)
        #expect(out.skipped == 0)
    }

    @Test func serializesPLSv2() {
        let tracks = [
            fileTrack("/tmp/x/a.mp3", title: "Title", artist: "Artist", duration: 61),
            fileTrack("/music/b.mp3", title: "Bee"),
        ]
        let out = PlaylistFile.serialize(tracks, format: .pls, playlistURL: URL(filePath: "/tmp/x/list.pls"))
        #expect(String(decoding: out.data, as: UTF8.self) == """
        [playlist]
        File1=a.mp3
        Title1=Artist - Title
        Length1=61
        File2=/music/b.mp3
        Title2=Bee
        Length2=-1
        NumberOfEntries=2
        Version=2

        """)
    }

    @Test func roundTripsM3UAndPLS() {
        let originals = ["/tmp/x/a.mp3", "/tmp/x/Björk/01 Hunter.mp3", "/elsewhere/with space/c.flac"]
        let tracks = originals.map { fileTrack($0, title: "t", duration: 3) }
        for (format, name) in [(PlaylistFile.Format.m3u, "list.m3u8"), (.pls, "list.pls")] {
            let url = URL(filePath: "/tmp/x/\(name)")
            let data = PlaylistFile.serialize(tracks, format: format, playlistURL: url).data
            let entries = PlaylistFile.parse(data, format: PlaylistFile.format(for: url, data: data), pathExtension: url.pathExtension)
            #expect(paths(entries, relativeTo: url) == originals)
        }
    }

    @Test func resolvesColonNamesAsRelativePaths() {
        let entries = ["AC:DC - x.mp3", "AC:DC/Back in Black/01.mp3", "./AC:DC - y.mp3", "a:b.mp3"]
            .map { PlaylistFile.Entry(location: $0) }
        #expect(paths(entries) == [
            "/tmp/x/AC:DC - x.mp3", "/tmp/x/AC:DC/Back in Black/01.mp3", "/tmp/x/AC:DC - y.mp3", "/tmp/x/a:b.mp3",
        ])
    }

    @Test func skipsOnlySchemeURLsAsStreams() {
        for location in ["http://r.example/s", "HTTPS://r.example/s", "mms://r.example/s", "rtsp://r.example/s", "icy://r.example/s"] {
            #expect(PlaylistFile.resolve(.init(location: location), relativeTo: listURL)
                == .skip(location: location, reason: "streams are not supported"))
        }
        let entries = ["file:///abs/d.mp3", "file:/abs/e.mp3"].map { PlaylistFile.Entry(location: $0) }
        #expect(paths(entries) == ["/abs/d.mp3", "/abs/e.mp3"])
    }

    @Test func serializeEscapesHashAndColonNames() {
        let tracks = ["/tmp/x/#1 Hit.mp3", "/tmp/x/AC:DC - x.mp3", "/tmp/x/AC:DC/01.mp3", "/tmp/x/sub/#b.mp3",
                      "/elsewhere/AC:DC.mp3", "/elsewhere/#c.mp3"].map { fileTrack($0, title: "t") }
        let expected = ["./#1 Hit.mp3", "./AC:DC - x.mp3", "./AC:DC/01.mp3", "sub/#b.mp3",
                        "/elsewhere/AC:DC.mp3", "/elsewhere/#c.mp3"]
        let m3u = String(decoding: PlaylistFile.serialize(tracks, format: .m3u, playlistURL: listURL).data, as: UTF8.self)
        #expect(m3u.split(separator: "\n").filter { !$0.hasPrefix("#EXT") }.map(String.init) == expected)
        let plsURL = URL(filePath: "/tmp/x/list.pls")
        let pls = String(decoding: PlaylistFile.serialize(tracks, format: .pls, playlistURL: plsURL).data, as: UTF8.self)
        #expect(pls.split(separator: "\n").filter { $0.hasPrefix("File") }.map { String($0.split(separator: "=", maxSplits: 1)[1]) } == expected)
    }

    @Test func roundTripsHashAndColonNames() {
        let originals = ["/tmp/x/#1 Hit.mp3", "/tmp/x/AC:DC - x.mp3", "/tmp/x/AC:DC/01.mp3", "/tmp/x/sub/#b.mp3",
                         "/elsewhere/AC:DC.mp3", "/elsewhere/#c.mp3"]
        let tracks = originals.map { fileTrack($0, title: "t", duration: 3) }
        for (format, name) in [(PlaylistFile.Format.m3u, "list.m3u"), (.m3u, "list.m3u8"), (.pls, "list.pls")] {
            let url = URL(filePath: "/tmp/x/\(name)")
            let data = PlaylistFile.serialize(tracks, format: format, playlistURL: url).data
            let entries = PlaylistFile.parse(data, format: PlaylistFile.format(for: url, data: data), pathExtension: url.pathExtension)
            #expect(paths(entries, relativeTo: url) == originals)
        }
    }

    @Test func decodesUTF16WithBOM() {
        let text = "#EXTM3U\n#EXTINF:120,Björk - Hunter\nBjörk/01 Hunter.mp3\n"
        let utf8 = PlaylistFile.parse(Data(text.utf8), format: .m3u)
        #expect(utf8 == [.init(location: "Björk/01 Hunter.mp3", title: "Björk - Hunter", duration: 120)])
        let le = Data([0xFF, 0xFE]) + text.data(using: .utf16LittleEndian)!
        let be = Data([0xFE, 0xFF]) + text.data(using: .utf16BigEndian)!
        #expect(PlaylistFile.parse(le, format: .m3u) == utf8)
        #expect(PlaylistFile.parse(be, format: .m3u) == utf8)
    }

    @Test func plsInUTF16IsDetected() {
        let text = "[playlist]\nFile1=a.mp3\nNumberOfEntries=1\n"
        let data = Data([0xFF, 0xFE]) + text.data(using: .utf16LittleEndian)!
        #expect(PlaylistFile.format(for: listURL, data: data) == .pls)
        #expect(PlaylistFile.parse(data, format: .pls) == [.init(location: "a.mp3")])
    }

    @Test func decodesBOMlessUTF16M3U() {
        let text = "#EXTM3U\n#EXTINF:120,Björk - Hunter\nBjörk/01 Hunter.mp3\n"
        let expected: [PlaylistFile.Entry] = [.init(location: "Björk/01 Hunter.mp3", title: "Björk - Hunter", duration: 120)]
        #expect(PlaylistFile.parse(Data(text.utf8), format: .m3u) == expected)
        for encoding in [String.Encoding.utf16LittleEndian, .utf16BigEndian] {
            let data = text.data(using: encoding)!
            #expect(PlaylistFile.parse(data, format: .m3u) == expected)
            #expect(PlaylistFile.parse(data, format: .m3u, pathExtension: "m3u8") == expected)
        }
    }

    @Test func decodesBOMlessUTF16PLS() {
        let text = "[playlist]\nFile1=Café/a.mp3\nTitle1=Café\nNumberOfEntries=1\n"
        for encoding in [String.Encoding.utf16LittleEndian, .utf16BigEndian] {
            let data = text.data(using: encoding)!
            #expect(PlaylistFile.format(for: URL(filePath: "/tmp/x/list.m3u"), data: data) == .pls)
            #expect(PlaylistFile.parse(data, format: .pls) == [.init(location: "Café/a.mp3", title: "Café")])
        }
    }

    @Test func bomlessUTF16DetectionLeavesUTF8AndWindows1252Alone() {
        let utf8 = Data("#EXTM3U\nBjörk/a.mp3\n".utf8)
        #expect(PlaylistFile.parse(utf8, format: .m3u).map(\.location) == ["Björk/a.mp3"])
        #expect(PlaylistFile.decode(utf8, pathExtension: "m3u") == "#EXTM3U\nBjörk/a.mp3\n")
        let cp1252 = Data("Caf".utf8) + Data([0xE9]) + Data(".mp3\n".utf8)
        #expect(PlaylistFile.parse(cp1252, format: .m3u, pathExtension: "m3u").map(\.location) == ["Café.mp3"])
        let decoded = PlaylistFile.decode(cp1252, pathExtension: "m3u")
        #expect(decoded == "Café.mp3\n")
        #expect(!decoded.contains("\u{0}"))
    }

    @Test func bomlessUTF16ToleratesTinyAndOddLengthData() {
        for data in [Data(), Data([0x00]), Data([0x61, 0x00]), Data([0x00, 0x61, 0x00])] {
            #expect(PlaylistFile.decode(data, pathExtension: "m3u").count <= 3)
        }
        let odd = "a.mp3\nb.mp3\n".data(using: .utf16LittleEndian)! + Data([0x00])
        #expect(PlaylistFile.parse(odd, format: .m3u).map(\.location) == ["a.mp3", "b.mp3"])
    }
}

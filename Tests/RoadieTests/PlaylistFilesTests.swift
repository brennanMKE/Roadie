import AppKit
import AudioCore
import Foundation
import LibraryBrowser
import MusicBackendKit
import MusicBackendStub
import PlayerKitTestFixtures
import UniformTypeIdentifiers
import XCTest

@testable import Roadie

/// LIST › Load / Save and the Library playlists' M3U8 export and import (#0218), through `panelChooserOverride`
/// instead of the real panels. Files live in temp folders; the Library side is a `StubMusicBackend`.
@MainActor
final class PlaylistFilesTests: PlayerModelTestCase {
    private var panelRequests: [PlayerModel.PanelRequest] = []

    override func tearDown() async throws {
        panelRequests = []
        try await super.tearDown()
    }

    /// Answers every panel with `url` (nil: cancelled) and records the request.
    private func answerPanels(_ model: PlayerModel, with url: URL?) {
        model.panelChooserOverride = { [weak self] request in
            self?.panelRequests.append(request)
            return url
        }
    }

    private func noticeText(_ model: PlayerModel) -> String? { model.notice?.text }

    private func fileNames(_ model: PlayerModel) -> [String] {
        model.player.queue.tracks.map { track in
            switch track.source {
            case .file(let url): url.lastPathComponent
            }
        }
    }

    func testLoadPlaylistFileFillsQueue() async throws {
        let model = try makeModel()
        let root = try temporaryDirectory("roadie-playlist-load")
        try AudioFixtures.makeLibrary(at: root)
        restoreThreeTracks(model)

        // Cancelled: the queue stays.
        answerPanels(model, with: nil)
        model.loadPlaylistFile()
        try await waitUntil("the load panel") { panelRequests == [.loadPlaylistFile] }
        XCTAssertEqual(fileNames(model), ["Tone A.mp3", "Tone B.mp3", "Tone C.mp3"])

        // The fixture M3U: three entries, relative to the playlist's folder.
        answerPanels(model, with: root.appending(path: AudioFixtures.playlistName))
        model.loadPlaylistFile()
        try await waitUntil("the M3U's tracks") {
            fileNames(model) == ["01 Tone A.mp3", "06 Tone F.wav", "Single.m4a"]
        }

        // A PLS fixture.
        let pls = root.appending(path: "Two.pls")
        try Data("""
            [playlist]
            File1=Tone Artist/Tone Album/02 Tone B.mp3
            File2=Tone Artist/Tone Album/03 Tone C.m4a
            NumberOfEntries=2
            Version=2

            """.utf8).write(to: pls)
        answerPanels(model, with: pls)
        model.loadPlaylistFile()
        try await waitUntil("the PLS's tracks") { fileNames(model) == ["02 Tone B.mp3", "03 Tone C.m4a"] }
        model.player.stop()
    }

    func testSavePlaylistFileRoundTrips() async throws {
        let model = try makeModel()
        let root = try temporaryDirectory("roadie-playlist-save")
        try AudioFixtures.makeLibrary(at: root)
        let album = root.appending(path: "\(AudioFixtures.artist)/\(AudioFixtures.album)", directoryHint: .isDirectory)
        let loaded = await LocalTrackLoader.load([album])
        XCTAssertEqual(loaded.tracks.count, 3)
        model.player.clearQueue()
        model.player.restoreQueue(loaded.tracks, currentIndex: 0, repeatMode: .off, isShuffled: false)
        let saved = fileNames(model)

        for name in ["Saved.m3u8", "Saved.m3u", "Saved.pls"] {
            let url = root.appending(path: name)
            answerPanels(model, with: url)
            model.savePlaylistFile()
            try await waitUntil("\(name) written") { FileManager.default.fileExists(atPath: url.path) }
            let text = try String(contentsOf: url, encoding: .utf8)
            if name.hasSuffix(".pls") {
                XCTAssertTrue(text.hasPrefix("[playlist]"), text)
                XCTAssertTrue(text.contains("File1=Tone Artist/Tone Album/01 Tone A.mp3"), text)
            } else {
                XCTAssertTrue(text.hasPrefix("#EXTM3U"), text)
                XCTAssertTrue(text.contains("\nTone Artist/Tone Album/01 Tone A.mp3\n"), text)
            }
            XCTAssertEqual(noticeText(model), "Saved 3 tracks")

            // Read back: the same files, in order.
            model.player.clearQueue()
            answerPanels(model, with: url)
            model.loadPlaylistFile()
            try await waitUntil("\(name) read back") { fileNames(model) == saved }
            model.player.stop()
        }
    }

    func testSavePlaylistFileNotices() async throws {
        let model = try makeModel()
        let root = try temporaryDirectory("roadie-playlist-notices")
        answerPanels(model, with: root.appending(path: "Never.m3u"))

        // An empty queue: no panel.
        model.player.clearQueue()
        model.savePlaylistFile()
        XCTAssertEqual(noticeText(model), "Nothing to save")
        XCTAssertEqual(panelRequests, [])

        // One track.
        let one = Track(title: "Tone A", artist: "", duration: 3, source: .file(AudioFixtures.url(.toneAmp3)))
        model.player.restoreQueue([one], currentIndex: nil, repeatMode: .off, isShuffled: false)
        let single = root.appending(path: "One.m3u")
        answerPanels(model, with: single)
        model.savePlaylistFile()
        try await waitUntil("the saved notice") { noticeText(model) == "Saved 1 track" }
        XCTAssertTrue(FileManager.default.fileExists(atPath: single.path))

        // An unwritable destination (its folder doesn't exist).
        answerPanels(model, with: root.appending(path: "Missing/Out.m3u"))
        model.savePlaylistFile()
        try await waitUntil("the failure notice") { noticeText(model) == "Could not save Out.m3u" }
        XCTAssertNotNil(model.notice?.detail)

        // Cancelled: nothing written, the notice stays.
        panelRequests = []
        answerPanels(model, with: nil)
        model.savePlaylistFile()
        try await waitUntil("the save panel") { panelRequests == [.savePlaylistFile] }
        XCTAssertEqual(noticeText(model), "Could not save Out.m3u")
    }

    func testExportImportLibraryPlaylist() async throws {
        let model = try makeModel()
        let root = try temporaryDirectory("roadie-playlist-m3u8")
        var library = StubLibrary.sample(artistCount: 2, albumsPerArtist: 1, tracksPerAlbum: 2, playlistCount: 1)
        for index in library.playlists.indices {
            library.playlists[index].isEditable = true
            library.playlists[index].libraryID = library.playlists[index].id.rawValue
        }
        let backend = StubMusicBackend(library: library, capabilities: [.playlists, .playlistEditing])
        let playlists = PlaylistsModel(backend: backend, list: PagedList<LibraryPlaylist>())
        let playlist = try XCTUnwrap(library.playlists.first)

        // Export: the backend's M3U8 text, under the chosen name.
        let exported = root.appending(path: "Exported.m3u8")
        answerPanels(model, with: exported)
        model.exportLibraryPlaylist(playlist, in: playlists)
        try await waitUntil("the export notice") { noticeText(model) == "Exported \u{201C}\(playlist.name)\u{201D}" }
        XCTAssertEqual(panelRequests, [.exportLibraryPlaylist(name: playlist.name)])
        let expected = try await backend.exportPlaylist(playlist.id)
        XCTAssertTrue(expected.hasPrefix("#EXTM3U"))
        XCTAssertEqual(try String(contentsOf: exported, encoding: .utf8), expected)

        // Export to an unwritable place.
        answerPanels(model, with: root.appending(path: "Missing/Out.m3u8"))
        model.exportLibraryPlaylist(playlist, in: playlists)
        try await waitUntil("the export failure") { noticeText(model) == "Could not save Out.m3u8" }

        // Import: the file's text goes to the backend.
        let text = "#EXTM3U\n#EXTINF:-1,Song\nlibrary://track/1\n"
        let source = root.appending(path: "In.m3u")
        try Data(text.utf8).write(to: source)
        panelRequests = []
        answerPanels(model, with: source)
        model.importLibraryPlaylist(in: playlists)
        try await waitUntil("the import notice") { noticeText(model) == "Imported \u{201C}Imported Playlist\u{201D}" }
        XCTAssertEqual(panelRequests, [.importLibraryPlaylist])
        let imports = await backend.calls(.importPlaylist)
        XCTAssertEqual(imports, [.importPlaylist(text)])

        // A file that can't be read: nothing is sent.
        answerPanels(model, with: root.appending(path: "Gone.m3u"))
        model.importLibraryPlaylist(in: playlists)
        try await waitUntil("the read failure") { noticeText(model) == "Could not read Gone.m3u" }
        let importCount = await backend.count(.importPlaylist)
        XCTAssertEqual(importCount, 1)
    }

    func testFormatChooserSetsType() throws {
        let panel = NSSavePanel()
        let chooser = PlaylistFormatChooser(panel: panel)
        let m3u8 = try XCTUnwrap(UTType(filenameExtension: "m3u8", conformingTo: .data))
        let m3u = try XCTUnwrap(UTType(filenameExtension: "m3u", conformingTo: .data))
        let pls = try XCTUnwrap(UTType(filenameExtension: "pls", conformingTo: .data))
        XCTAssertEqual(panel.allowedContentTypes, [m3u8], "M3U8 is the default")
        chooser.apply(index: 2)
        XCTAssertEqual(panel.allowedContentTypes, [pls])
        chooser.apply(index: 1)
        XCTAssertEqual(panel.allowedContentTypes, [m3u])
        chooser.apply(index: 7)
        XCTAssertEqual(panel.allowedContentTypes, [m3u], "an index past the popup changes nothing")
        XCTAssertNotNil(chooser.view.subviews.first { $0 is NSPopUpButton })
    }
}

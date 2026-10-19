import Foundation
import Testing
@testable import AudioCore

@Suite struct PlaylistSortKeyTests {
    @Test func fileNameAndPathKeys() {
        let t = Track(title: "x", artist: "", duration: 1, source: .file(URL(filePath: "/music/a/b.mp3")))
        #expect(PlaylistSortKey.fileName(t) == "b.mp3")
        #expect(PlaylistSortKey.path(t) == "/music/a/b.mp3")
    }

    @Test func nonFileTracksFallBackToTitle() {
        let t = Track(title: "Plex Song", artist: "", duration: 1, source: .plex(partKey: "/p", cacheKey: "k"))
        #expect(PlaylistSortKey.fileName(t) == "Plex Song")
        #expect(PlaylistSortKey.path(t) == "Plex Song")
    }
}

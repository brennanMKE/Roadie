import Foundation
import Testing
@testable import AudioCore

@Suite struct PlaylistSortKeyTests {
    @Test func fileNameAndPathKeys() {
        let t = Track(title: "x", artist: "", duration: 1, source: .file(URL(filePath: "/music/a/b.mp3")))
        #expect(PlaylistSortKey.fileName(t) == "b.mp3")
        #expect(PlaylistSortKey.path(t) == "/music/a/b.mp3")
    }
}

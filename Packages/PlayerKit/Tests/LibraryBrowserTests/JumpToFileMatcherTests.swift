import Foundation
import Testing
@testable import LibraryBrowser

@Suite struct JumpToFileMatcherTests {
    private let sample = JumpToFileIndex([
        JumpToFileEntry(artist: "Daft Punk", title: "Technologic"),
        JumpToFileEntry(artist: "Daft Punk", title: "One More Time"),
        JumpToFileEntry(artist: "Tech N9ne", title: "Fragile"),
    ])

    @Test func emptyQueryMatchesEveryRowInOrder() {
        #expect(sample.matches("") == [0, 1, 2])
        #expect(sample.matches("   ") == [0, 1, 2])
    }

    @Test func everyTokenMustMatch() {
        #expect(sample.matches("daft tech") == [0])
        #expect(sample.matches("tech daft") == [0])
    }

    @Test func matchingFoldsCaseAndDiacritics() {
        let index = JumpToFileIndex([
            JumpToFileEntry(artist: "Beyoncé", title: "Halo"),
            JumpToFileEntry(artist: "Sigur Rós", title: "Hoppipolla"),
            JumpToFileEntry(artist: "Daft", title: "X"),
        ])
        #expect(index.matches("beyonce") == [0])
        #expect(index.matches("SIGUR ROS") == [1])
        #expect(index.matches("ｄａｆｔ") == [2])
    }

    @Test func tokensMatchArtistTitleAlbumOrFileName() {
        let index = JumpToFileIndex([
            JumpToFileEntry(artist: "Aphex", title: "Xtal", album: "Ambient", fileName: "03 Intro.flac"),
            JumpToFileEntry(artist: "Other", title: "Song"),
        ])
        #expect(index.matches("aphex") == [0])
        #expect(index.matches("xtal") == [0])
        #expect(index.matches("ambient") == [0])
        #expect(index.matches("intro.flac") == [0])
    }

    @Test func tokensDoNotSpanFields() {
        let index = JumpToFileIndex([JumpToFileEntry(artist: "Daft", title: "Punk")])
        #expect(index.matches("daftpunk") == [])
        #expect(index.matches("daft punk") == [0])
    }

    @Test func displayedTextMatches() {
        #expect(sample.matches("daft punk - technologic") == [0])
    }

    @Test func resultsKeepPlaylistOrder() {
        let entries = (0..<10).map { i in
            JumpToFileEntry(artist: [7, 2, 5].contains(i) ? "Needle" : "Hay", title: "T\(i)")
        }
        #expect(JumpToFileIndex(entries).matches("needle") == [2, 5, 7])
    }

    @Test func cancelledMatchReturnsNil() {
        let index = JumpToFileIndex((0..<5000).map { JumpToFileEntry(artist: "a\($0)", title: "b") })
        #expect(index.matches("a", isCancelled: { true }) == nil)
    }

    @Test func fiftyThousandRowsFilterQuickly() {
        let entries = (0..<50_000).map { i in
            JumpToFileEntry(artist: "Artist \(i % 997)", title: "Title \(i)", album: "Album \(i % 4001)")
        }
        let clock = ContinuousClock()
        var index = JumpToFileIndex([])
        let build = clock.measure { index = JumpToFileIndex(entries) }
        var result: [Int] = []
        let query = clock.measure { result = index.matches("artist 42 title 1") }
        print("JumpToFileIndex 50k rows: init \(build), match \(query), \(result.count) matches")
        #expect(index.count == 50_000)
        #expect(!result.isEmpty)
        #expect(build < .seconds(3))
        #expect(query < .milliseconds(200))
    }
}

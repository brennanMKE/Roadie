import Testing
@testable import SkinKit

@Suite struct PlaylistTextTests {
    @Test func rowNumbersPadWithNoBreakSpaces() {
        #expect(PlaylistText.rowNumber(0, count: 12) == "\u{00A0}1. ")
        #expect(PlaylistText.rowNumber(11, count: 12) == "12. ")
        #expect(PlaylistText.rowNumber(0, count: 9) == "1. ")
        #expect(PlaylistText.rowNumber(0, count: 0) == "1. ")
    }

    @Test func displayNameFollowsWebampTrackName() {
        #expect(PlaylistText.displayName(artist: "A", title: "T", fileName: "f.mp3") == "A - T")
        #expect(PlaylistText.displayName(artist: "", title: "T", fileName: "f.mp3") == "T")
        #expect(PlaylistText.displayName(artist: "A", title: "", fileName: "f.mp3") == "f.mp3")
        #expect(PlaylistText.displayName(artist: "", title: "", fileName: "f.mp3") == "f.mp3")
    }

    @Test func runningTimeIsSelectedOverTotalPaddedToEighteen() {
        #expect(PlaylistText.runningTime(selected: 0, total: 754) == "0:00/12:34" + String(repeating: " ", count: 8))
        #expect(PlaylistText.runningTime(selected: 0, total: 3661).hasPrefix("0:00/61:01"))
        #expect(PlaylistText.runningTime(selected: 0, total: 0).count == 18)
    }

    @Test func queueMarkerIsBracketedOneBasedOrEmpty() {
        #expect(PlaylistText.queueMarker(1) == "[1]")
        #expect(PlaylistText.queueMarker(12) == "[12]")
        #expect(PlaylistText.queueMarker(nil) == "")
        #expect(PlaylistText.queueMarker(0) == "")
        #expect(PlaylistText.queueMarker(-1) == "")
    }

    @Test func timeIsBlankWhenUnknown() {
        #expect(PlaylistText.time(nil) == "")
        #expect(PlaylistText.time(.nan) == "")
        #expect(PlaylistText.time(-1) == "")
        #expect(PlaylistText.time(65.9) == "1:05")
        #expect(PlaylistText.time(600) == "10:00")
    }
}

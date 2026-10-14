import MusicBackendKit
import Testing
@testable import LibraryBrowser

@MainActor
struct LibraryFormatTests {
    @Test func durationFormatsMinutesAndHours() {
        #expect(LibraryFormat.duration(186.015) == "3:06")
        #expect(LibraryFormat.duration(3723) == "1:02:03")
        #expect(LibraryFormat.duration(0) == "0:00")
        #expect(LibraryFormat.duration(nil) == "\u{2013}:\u{2013}\u{2013}")
    }

    @Test func trackNumberShowsTheDiscOnlyWhenNeeded() {
        func track(disc: Int?, number: Int?) -> LibraryTrack {
            LibraryTrack(
                id: MediaID(.track, "t"), title: "T", artistName: "A", trackNumber: number, discNumber: disc)
        }
        #expect(LibraryFormat.trackNumber(track(disc: nil, number: 9)) == "9")
        #expect(LibraryFormat.trackNumber(track(disc: 1, number: 9)) == "9")
        #expect(LibraryFormat.trackNumber(track(disc: 2, number: 3)) == "2-3")
        #expect(LibraryFormat.trackNumber(track(disc: 2, number: nil)) == "")
    }

    @Test func countLabelNeedsATotal() {
        #expect(LibraryFormat.countLabel(loaded: 23, total: 242) == "23 of 242")
        #expect(LibraryFormat.countLabel(loaded: 23, total: nil) == nil)
    }
}

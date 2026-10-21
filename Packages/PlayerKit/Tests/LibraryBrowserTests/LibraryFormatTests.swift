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

    @Test func countUsesTheSingularForOne() {
        #expect(LibraryFormat.count(0, "track") == "0 tracks")
        #expect(LibraryFormat.count(1, "track") == "1 track")
        #expect(LibraryFormat.count(2, "track") == "2 tracks")
    }

    @Test func trackSummaryUsesTheSingularForOne() {
        #expect(LibraryFormat.trackSummary(count: 1, duration: 221) == "1 track, 3:41")
        #expect(LibraryFormat.trackSummary(count: 2, duration: 442) == "2 tracks, 7:22")
    }
}

import Foundation
import Testing
@testable import AudioCore

@Suite struct StatusNoticeTests {
    private func imported(_ tracks: Int, skipped: Int) -> LocalImport {
        LocalImport(
            tracks: makeTracks(tracks),
            skipped: (0..<skipped).map { SkippedFile(url: URL(filePath: "/x\($0).txt"), reason: "not an audio file") })
    }

    @Test func skippedTextCountsAndPluralizes() {
        #expect(StatusNotice.skipped(imported(0, skipped: 1))?.text == "Skipped 1 file")
        #expect(StatusNotice.skipped(imported(0, skipped: 3))?.text == "Skipped 3 files")
        #expect(StatusNotice.skipped(imported(4, skipped: 1))?.text == "Skipped 1 of 5 files")
        #expect(StatusNotice.skipped(imported(1, skipped: 1))?.text == "Skipped 1 of 2 files")
        for (t, s) in [(0, 1), (0, 3), (4, 1), (1, 1), (120, 45)] {
            let notice = StatusNotice.skipped(imported(t, skipped: s))
            #expect(notice?.detail == "see Console")
            #expect((notice?.text.utf16.count ?? 0) <= 31)
        }
    }

    @Test func nothingSkippedMeansNoNotice() {
        #expect(StatusNotice.skipped(imported(3, skipped: 0)) == nil)
        #expect(StatusNotice.skipped(imported(0, skipped: 0)) == nil)
    }

    @Test func noticeExpiresAfterItsDuration() {
        let t0 = ContinuousClock.now
        let n = StatusNotice(text: "x", shownAt: t0)
        #expect(n.isActive(at: t0))
        #expect(n.isActive(at: t0 + .seconds(3) - .milliseconds(1)))
        #expect(!n.isActive(at: t0 + .seconds(3)))
        #expect(n.expiresAt == t0 + StatusNotice.duration)
        #expect(StatusNotice.duration == .seconds(3))
    }

    @Test func skinFailedNamesTheSkin() {
        let t0 = ContinuousClock.now
        let n = StatusNotice.skinFailed("Pika_Amp", shownAt: t0)
        #expect(n.text == "Could not load Pika_Amp")
        #expect(n.detail == nil)
        #expect(n != StatusNotice.skinFailed("Pika_Amp", shownAt: t0 + .seconds(1)))
    }
}

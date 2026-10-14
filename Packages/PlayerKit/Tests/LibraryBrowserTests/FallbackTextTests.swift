import Testing
@testable import LibraryBrowser

struct FallbackTextTests {
    private func status(
        preferred: (String, String), active: (String, String), reason: FallbackReason?
    ) -> FallbackStatus {
        FallbackStatus(
            preferredID: preferred.0, preferredName: preferred.1, activeID: active.0, activeName: active.1,
            reason: reason)
    }

    @Test func noticesFitTheMarquee() {
        let names = [("plex", "Plex"), ("folder", "Local Folder"), ("musicAssistant", "Music Assistant")]
        for preferred in names {
            for active in names where active.0 != preferred.0 {
                let missing = status(preferred: preferred, active: active, reason: .notConfigured)
                let down = status(preferred: preferred, active: active, reason: .unreachable("x"))
                let notice = FallbackText.notice(kind: .fallback, status: missing)
                #expect(notice.text == "Using \(active.1)")
                #expect(notice.detail == "\(preferred.1) isn't set up")
                #expect(FallbackText.notice(kind: .fallback, status: down).detail == "\(preferred.1) can't be reached")
                let restored = status(preferred: preferred, active: preferred, reason: nil)
                let back = FallbackText.notice(kind: .restore, status: restored)
                #expect(back.text == "Back on \(preferred.1)")
                #expect(back.detail == nil)
                #expect(notice.text.utf16.count <= 31)
                #expect(back.text.utf16.count <= 31)
            }
        }
    }

    @Test func summaryAndSubtitleDescribeTheFallback() {
        let same = status(preferred: ("plex", "Plex"), active: ("plex", "Plex"), reason: nil)
        #expect(FallbackText.summary(same) == nil)
        #expect(FallbackText.subtitle(same) == "Plex")
        let missing = status(preferred: ("plex", "Plex"), active: ("folder", "Local Folder"), reason: .notConfigured)
        #expect(FallbackText.summary(missing) == "Using Local Folder: Plex isn't set up.")
        let down = status(preferred: ("plex", "Plex"), active: ("folder", "Local Folder"), reason: .unreachable("x"))
        #expect(FallbackText.summary(down)
            == "Using Local Folder: Plex can't be reached. SkinAmp switches back when it is.")
        #expect(FallbackText.subtitle(down) == "Local Folder (Plex unavailable)")
    }
}

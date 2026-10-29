import Foundation
import Testing
@testable import VisualizationKit

struct OverlayVisibilityTests {
    @Test func startsVisibleAndHidesAfterTheTimeout() {
        var overlay = OverlayVisibility(idleTimeout: 3, now: 0)
        #expect(overlay.isOverlayVisible)
        overlay.tick(at: 2.9)
        #expect(overlay.isOverlayVisible)
        #expect(!overlay.isCursorHidden)
        overlay.tick(at: 3.0)
        #expect(!overlay.isOverlayVisible)
        #expect(overlay.isCursorHidden)
    }

    @Test func movementShowsItAgainAndRestartsTheCountdown() {
        var overlay = OverlayVisibility(idleTimeout: 3, now: 0)
        overlay.tick(at: 3)
        overlay.pointerMoved(at: 4, inside: true)
        #expect(overlay.isOverlayVisible)
        #expect(!overlay.isCursorHidden)
        overlay.tick(at: 6.9)
        #expect(overlay.isOverlayVisible)
        overlay.tick(at: 7)
        #expect(!overlay.isOverlayVisible)
    }

    @Test func cursorStaysVisibleWhenThePointerIsOutside() {
        var overlay = OverlayVisibility(idleTimeout: 3, now: 0)
        overlay.pointerExited(at: 1)
        overlay.tick(at: 3)
        #expect(!overlay.isOverlayVisible)
        #expect(!overlay.isCursorHidden)
    }

    @Test func holdsKeepItUp() {
        let all: [OverlayVisibility.Hold] = [.notPlaying, .voiceOver, .browser, .help, .menu, .pointerOnOverlay, .notice]
        for hold in all {
            var overlay = OverlayVisibility(idleTimeout: 3, now: 0)
            overlay.tick(at: 3)
            overlay.setHolds([hold], at: 4)
            #expect(overlay.isOverlayVisible, "\(hold)")
            #expect(!overlay.isCursorHidden, "\(hold)")
            overlay.tick(at: 100)
            #expect(overlay.isOverlayVisible, "\(hold)")
            overlay.setHolds([], at: 100)
            overlay.tick(at: 102.9)
            #expect(overlay.isOverlayVisible, "\(hold)")
            overlay.tick(at: 103)
            #expect(!overlay.isOverlayVisible, "\(hold)")
        }
    }

    @Test func neverTimeoutNeverHides() {
        for timeout in [nil, 0] as [TimeInterval?] {
            var overlay = OverlayVisibility(idleTimeout: timeout, now: 0)
            overlay.tick(at: 10_000)
            #expect(overlay.isOverlayVisible)
            #expect(!overlay.isCursorHidden)
            #expect(overlay.nextDeadline == nil)
        }
    }

    @Test func nextDeadlineMatchesTheHideTime() {
        var overlay = OverlayVisibility(idleTimeout: 3, now: 0)
        #expect(overlay.nextDeadline == 3)
        overlay.pointerMoved(at: 5, inside: true)
        #expect(overlay.nextDeadline == 8)
        overlay.setHolds([.menu], at: 6)
        #expect(overlay.nextDeadline == nil)
        overlay.setHolds([], at: 9)
        #expect(overlay.nextDeadline == 12)
    }
}

import Testing
@testable import SkinKit

private func status(
    _ transport: Transport, mode: TimeMode = .elapsed, elapsed: Double = 0, duration: Double = 200,
    kbps: Int? = nil, hz: Double? = nil, channels: Int? = nil
) -> MainWindowStatus {
    MainWindowStatus(
        transport: transport, timeMode: mode, elapsed: elapsed, duration: duration,
        bitrateKbps: kbps, sampleRate: hz, channels: channels)
}

private func digits(_ a: Int, _ b: Int, _ c: Int, _ d: Int) -> TimeDigits {
    TimeDigits(minutesTens: a, minutesOnes: b, secondsTens: c, secondsOnes: d)
}

struct MainWindowStatusTests {
    @Test func stoppedHidesTimeAndMediaInfo() {
        let s = status(.stopped, kbps: 128, hz: 44100, channels: 2)
        #expect(!s.showsTime)
        #expect(s.digits == .blank)
        #expect(s.kbps == nil)
        #expect(s.khz == nil)
        #expect(!s.stereoSelected)
        #expect(!s.monoSelected)
        #expect(s.indicator == "MAIN_STOPPED_INDICATOR")
        #expect(s.workIndicator == nil)
    }

    @Test func playingShowsEverything() {
        let s = status(.playing, elapsed: 61, kbps: 128, hz: 44100, channels: 2)
        #expect(s.showsTime)
        #expect(s.digits == digits(0, 1, 0, 1))
        #expect(s.kbps == "128")
        #expect(s.khz == "44")
        #expect(s.stereoSelected)
        #expect(!s.monoSelected)
        #expect(s.indicator == "MAIN_PLAYING_INDICATOR")
        #expect(s.workIndicator == "MAIN_NOT_WORKING_INDICATOR")
    }

    @Test func pausedBlinks() {
        let s = status(.paused)
        #expect(s.showsTime)
        #expect(s.blinksTime)
        #expect(s.indicator == "MAIN_PAUSED_INDICATOR")
        #expect(s.workIndicator == nil)
        #expect(!status(.playing).blinksTime)
    }

    @Test func loadingShowsWorkIndicator() {
        let s = status(.loading)
        #expect(s.indicator == nil)
        #expect(s.workIndicator == "MAIN_WORKING_INDICATOR")
        #expect(s.digits == digits(0, 0, 0, 0))
        #expect(s.kbps == "  0")
    }

    @Test func remainingModeShowsMinus() {
        let remaining = status(.playing, mode: .remaining, elapsed: 10, duration: 70)
        #expect(remaining.showsMinus)
        #expect(remaining.digits == digits(0, 1, 0, 0))
        #expect(!status(.playing, mode: .elapsed, elapsed: 10, duration: 70).showsMinus)
        #expect(!status(.stopped, mode: .remaining).showsMinus)
    }

    @Test func monoSelectsMono() {
        let s = status(.playing, channels: 1)
        #expect(s.monoSelected)
        #expect(!s.stereoSelected)
    }

    @Test func multichannelSelectsNeither() {
        let s = status(.playing, channels: 6)
        #expect(!s.monoSelected)
        #expect(!s.stereoSelected)
    }
}

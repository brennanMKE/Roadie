import Testing
@testable import SkinKit

private func digits(_ a: Int, _ b: Int, _ c: Int, _ d: Int) -> TimeDigits {
    TimeDigits(minutesTens: a, minutesOnes: b, secondsTens: c, secondsOnes: d)
}

struct TimeDigitsTests {
    @Test func zeroIsFourZeros() { #expect(TimeDigits(seconds: 0) == digits(0, 0, 0, 0)) }
    @Test func fractionsFloor() { #expect(TimeDigits(seconds: 65.9) == digits(0, 1, 0, 5)) }
    @Test func remainingSubtractsAndFloors() {
        #expect(TimeDigits.shown(mode: .remaining, elapsed: 65.4, duration: 200) == digits(0, 2, 1, 4))
    }
    @Test func remainingNeverNegative() {
        #expect(TimeDigits.shown(mode: .remaining, elapsed: 201, duration: 200) == digits(0, 0, 0, 0))
    }
    @Test func clampsAtNinetyNineMinutes() { #expect(TimeDigits(seconds: 6000) == digits(9, 9, 5, 9)) }
    @Test func blankHasNoDigits() {
        let blank = TimeDigits.blank
        #expect(blank.minutesTens == nil && blank.minutesOnes == nil && blank.secondsTens == nil && blank.secondsOnes == nil)
    }
}

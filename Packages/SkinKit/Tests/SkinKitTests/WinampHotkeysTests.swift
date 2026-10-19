import Testing
@testable import SkinKit

struct WinampHotkeysTests {
    private func key(_ c: String, command: Bool = false, control: Bool = false, option: Bool = false,
                     shift: Bool = false, isRepeat: Bool = false) -> WinampHotkey? {
        WinampHotkeys.hotkey(charactersIgnoringModifiers: c, command: command, control: control, option: option,
                             shift: shift, isRepeat: isRepeat)
    }

    @Test func lettersMapToTransport() {
        #expect(key("z") == .previous)
        #expect(key("x") == .play)
        #expect(key("c") == .pause)
        #expect(key("v") == .stop)
        #expect(key("b") == .next)
        #expect(key("s") == .toggleShuffle)
        #expect(key("r") == .toggleRepeat)
        #expect(key("l") == .openFile)
    }

    @Test func capsLockLettersStillMap() {
        #expect(key("Z") == .previous)
    }

    @Test func arrowsMapToSeekAndVolume() {
        #expect(key("\u{F702}") == .seekBack)
        #expect(key("\u{F703}") == .seekForward)
        #expect(key("\u{F700}") == .volumeUp)
        #expect(key("\u{F701}") == .volumeDown)
    }

    @Test func modifiedKeysAreIgnored() {
        #expect(key("z", command: true) == nil)
        #expect(key("x", control: true) == nil)
        #expect(key("c", option: true) == nil)
        #expect(key("b", shift: true) == nil)
        #expect(key("\u{F702}", command: true) == nil)
        #expect(key("v", command: true, control: true) == nil)
    }

    @Test func repeatsOnlyForArrows() {
        #expect(key("b", isRepeat: true) == nil)
        #expect(key("\u{F703}", isRepeat: true) == .seekForward)
    }

    @Test func unmappedKeysAreIgnored() {
        for c in ["a", "1", " ", "\r", "\u{7F}", ""] { #expect(key(c) == nil) }
    }

    @Test func seekTargetClampsToTrack() {
        #expect(WinampHotkeys.seekTarget(elapsed: 2, duration: 100, forward: false) == 0)
        #expect(WinampHotkeys.seekTarget(elapsed: 98, duration: 100, forward: true) == 100)
        #expect(WinampHotkeys.seekTarget(elapsed: 50, duration: 100, forward: false) == 45)
        #expect(WinampHotkeys.seekTarget(elapsed: 50, duration: 100, forward: true) == 55)
    }

    @Test func seekTargetNeedsDuration() {
        #expect(WinampHotkeys.seekTarget(elapsed: 0, duration: 0, forward: true) == nil)
    }

    @Test func volumeNudgeClampsAndSteps() {
        #expect(abs(WinampHotkeys.nudgedVolume(0.5, up: true) - 0.51) < 0.0001)
        #expect(WinampHotkeys.nudgedVolume(1, up: true) == 1)
        #expect(WinampHotkeys.nudgedVolume(0, up: false) == 0)
    }
}

import Foundation
import Testing
@testable import VisualizationKit

struct VisKeyMapTests {
    private func map(
        _ key: VisKey, command: Bool = false, control: Bool = false, option: Bool = false, shift: Bool = false,
        isRepeat: Bool = false
    ) -> VisCommand? {
        VisKeyMap.command(for: key, command: command, control: control, option: option, shift: shift, isRepeat: isRepeat)
    }

    @Test func arrowsMovePresetsAndVolume() {
        #expect(map(.right) == .nextPreset)
        #expect(map(.space) == .nextPreset)
        #expect(map(.left) == .previousPreset)
        #expect(map(.delete) == .previousPreset)
        #expect(map(.up) == .transport(.volumeUp))
        #expect(map(.down) == .transport(.volumeDown))
        #expect(map(.up, isRepeat: true) == .transport(.volumeUp))
        #expect(map(.down, isRepeat: true) == .transport(.volumeDown))
        #expect(map(.right, isRepeat: true) == nil)
    }

    @Test func milkDropLettersMapToTheirCommands() {
        let table: [(String, VisCommand)] = [
            ("h", .hardCut), ("r", .toggleOrder), ("`", .toggleLock), ("l", .presetList), ("t", .showSongTitle),
            ("z", .transport(.previous)), ("x", .transport(.play)), ("c", .transport(.pause)),
            ("v", .transport(.stop)), ("b", .transport(.next)),
        ]
        for (letter, expected) in table {
            #expect(map(.character(letter)) == expected, "\(letter)")
            #expect(map(.character(letter.uppercased())) == expected, "\(letter.uppercased())")
        }
        #expect(map(.function(1)) == .help)
        #expect(map(.function(2)) == .toggleReadout(.title))
        #expect(map(.function(3)) == .toggleReadout(.time))
        #expect(map(.function(4)) == .toggleReadout(.preset))
        #expect(map(.function(5)) == .toggleReadout(.fps))
        #expect(map(.function(6)) == nil)
        #expect(map(.escape) == .escape)
        #expect(map(.character("q")) == nil)
    }

    @Test func commandAndControlCombinationsGoToTheMenuBar() {
        #expect(map(.right, command: true) == nil)
        #expect(map(.space, control: true) == nil)
        #expect(map(.character("l"), command: true) == nil)
        #expect(map(.up, command: true) == nil)
        #expect(map(.returnKey, command: true, option: true) == nil)
        #expect(map(.character("h"), shift: true) == nil)
        #expect(map(.character("?"), command: true, shift: true) == nil)
    }

    @Test func optionReturnTogglesFullScreenAndPlainReturnDoesNothing() {
        #expect(map(.returnKey, option: true) == .toggleFullScreen)
        #expect(map(.returnKey) == nil)
        #expect(map(.character("h"), option: true) == nil)
    }

    @Test func heldLettersDoNotRepeat() {
        for letter in ["h", "r", "`", "l", "t", "z", "x", "c", "v", "b", "?"] {
            #expect(map(.character(letter), isRepeat: true) == nil, "\(letter)")
        }
        #expect(map(.left, isRepeat: true) == nil)
        #expect(map(.space, isRepeat: true) == nil)
    }

    @Test func questionMarkOpensHelpWithOrWithoutShift() {
        #expect(map(.character("?")) == .help)
        #expect(map(.character("?"), shift: true) == .help)
    }

    @Test func everyCommandHasAHelpRow() {
        let commands = Set(VisKeyMap.rows.map(\.command))
        var expected: Set<VisCommand> = [
            .nextPreset, .previousPreset, .hardCut, .toggleOrder, .toggleLock, .presetList, .showSongTitle, .help,
            .toggleFullScreen,
        ]
        for readout in VisReadout.allCases { expected.insert(.toggleReadout(readout)) }
        for transport: VisTransport in [.previous, .play, .pause, .stop, .next, .volumeUp, .volumeDown] {
            expected.insert(.transport(transport))
        }
        #expect(commands == expected)
        #expect(VisKeyMap.rows.count == expected.count)
        #expect(VisKeyMap.rows.allSatisfy { !$0.keys.isEmpty && !$0.title.isEmpty })
    }
}

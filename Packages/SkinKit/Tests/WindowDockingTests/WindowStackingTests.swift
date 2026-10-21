import Testing
@testable import WindowDocking

private typealias P = WindowStacking.Placement<String>
private let group: Set<String> = ["main", "equalizer", "playlist"]

@Suite struct WindowStackingTests {
    @Test func raisePutsTheOthersDirectlyBelowTheKeyInTheirOrder() {
        let steps = WindowStacking.raise(group: group, key: "main", frontToBack: ["playlist", "library", "main", "equalizer"])
        #expect(steps == [P(window: "playlist", below: "main"), P(window: "equalizer", below: "playlist")])
    }

    @Test func raiseKeepsTheOrderWhenTheKeyIsAlreadyInFront() {
        #expect(
            WindowStacking.raise(group: group, key: "main", frontToBack: ["main", "equalizer", "playlist"])
                == [P(window: "equalizer", below: "main"), P(window: "playlist", below: "equalizer")])
        #expect(
            WindowStacking.raise(group: group, key: "playlist", frontToBack: ["playlist", "equalizer", "main"])
                == [P(window: "equalizer", below: "playlist"), P(window: "main", below: "equalizer")])
    }

    @Test func raiseIgnoresWindowsOutsideTheGroupAndMembersNotOnScreen() {
        #expect(WindowStacking.raise(group: group, key: "main", frontToBack: ["settings", "main", "library"]).isEmpty)
        #expect(
            WindowStacking.raise(group: group, key: "main", frontToBack: ["library", "equalizer", "settings", "main"])
                == [P(window: "equalizer", below: "main")])
    }

    @Test func raiseWithoutAKeyMemberDoesNothing() {
        #expect(WindowStacking.raise(group: group, key: "library", frontToBack: ["library", "main"]).isEmpty)
        #expect(WindowStacking.raise(group: group, key: "main", frontToBack: ["equalizer", "playlist"]).isEmpty)
        #expect(
            WindowStacking.raise(group: group, key: "main", frontToBack: ["equalizer", "main", "equalizer"])
                == [P(window: "equalizer", below: "main")])
    }

    // #0120: the equalizer and playlist are child windows of main, which AppKit always keeps above it.
    private static func parent(_ id: String) -> String? { id == "main" ? nil : "main" }

    @Test func raiseNeverPutsAChildBelowItsParent() {
        let steps = WindowStacking.raise(
            group: group, key: "equalizer", frontToBack: ["equalizer", "main", "playlist"], parent: Self.parent)
        #expect(steps == [P(window: "main", below: "equalizer")])
    }

    @Test func raiseStillOrdersSiblingChildren() {
        let steps = WindowStacking.raise(
            group: group, key: "main", frontToBack: ["playlist", "main", "equalizer"], parent: Self.parent)
        #expect(steps == [P(window: "equalizer", below: "playlist")])
    }
}

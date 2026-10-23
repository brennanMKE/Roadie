import Foundation
import MusicBackendKit
import MusicBackendStub
import Testing
@testable import LibraryBrowser

/// #0121: what Roadie stops on quit, and that a dead connection never holds quitting up.
struct QuitStopTests {
    let mac = OutputDevice.thisMacID
    let homePod = OutputDevice.ID(rawValue: "homepod")

    @Test func quitTargetsTheSelectedSpeaker() {
        #expect(QuitStop.targets(enabled: true, isConnected: true, selected: homePod, thisMacFeed: .local) == [homePod])
        #expect(QuitStop.targets(enabled: true, isConnected: true, selected: mac, thisMacFeed: .local).isEmpty)
    }

    @Test func quitStopsGroupMembersToo() {
        let bedroom = OutputDevice.ID(rawValue: "bedroom")
        #expect(
            QuitStop.targets(
                enabled: true, isConnected: true, selected: mac, members: [homePod, bedroom], thisMacFeed: .musicAssistant)
                == [homePod, bedroom, mac])
        #expect(
            QuitStop.targets(enabled: true, isConnected: true, selected: homePod, members: [mac], thisMacFeed: .musicAssistant)
                == [homePod, mac])
    }

    @Test func quitTargetsThisMacWhenMusicAssistantFeedsIt() {
        #expect(QuitStop.targets(enabled: true, isConnected: true, selected: mac, thisMacFeed: .musicAssistant) == [mac])
        #expect(
            QuitStop.targets(enabled: true, isConnected: true, selected: homePod, thisMacFeed: .musicAssistant)
                == [homePod, mac])
    }

    @Test func quitWithToggleOffSendsNothing() async {
        let targets = QuitStop.targets(enabled: false, isConnected: true, selected: homePod, thisMacFeed: .musicAssistant)
        #expect(targets.isEmpty)
        let stub = StubMusicBackend()
        #expect(await QuitStop.run(targets, on: stub) == .sent)
        #expect(await stub.count(.transport) == 0)
    }

    @Test func quitWhenDisconnectedSendsNothing() {
        #expect(
            QuitStop.targets(enabled: true, isConnected: false, selected: homePod, thisMacFeed: .musicAssistant).isEmpty)
    }

    @Test func quitStopperSendsStopToEachTarget() async {
        let stub = StubMusicBackend()
        let outcome = await QuitStop.run([homePod, mac], on: stub, clock: ManualClock())
        #expect(outcome == .sent)
        let calls = Set(await stub.calls(.transport))
        #expect(calls == [.transport(.stop, homePod), .transport(.stop, mac)])
    }

    @Test func quitStopperTimesOutAndStillReturns() async {
        let stub = StubMusicBackend()
        await stub.gate(.transport)
        let clock = ManualClock()
        let homePod = homePod
        let run = Task { await QuitStop.run([homePod], on: stub, clock: clock) }
        #expect(await waitFor { await stub.suspendedCount == 1 && clock.sleeperCount == 1 })
        clock.advance(by: .milliseconds(1500))
        #expect(await run.value == .timedOut)
    }

    @Test func quitStopperWithNoTargetsReturnsAtOnce() async {
        let stub = StubMusicBackend()
        let clock = ManualClock()
        #expect(await QuitStop.run([], on: stub, clock: clock) == .sent)
        #expect(clock.sleeperCount == 0)
        #expect(await stub.count(.transport) == 0)
    }
}

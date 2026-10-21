import MusicBackendKit
import Testing
@testable import LibraryBrowser

@Suite struct OutputMoveTests {
    let kitchen = OutputDevice.ID(rawValue: "media_player.kitchen")
    let den = OutputDevice.ID(rawValue: "media_player.den")
    let mac = OutputDevice.thisMacID

    @Test func playingSpeakerToSpeakerTransfers() {
        #expect(OutputMove.decide(from: kitchen, to: den, sourceState: .playing, thisMacFeed: .local)
            == .transfer(autoPlay: true))
    }

    @Test func playingMusicAssistantOnThisMacToSpeakerTransfers() {
        #expect(OutputMove.decide(from: mac, to: kitchen, sourceState: .playing, thisMacFeed: .musicAssistant)
            == .transfer(autoPlay: true))
    }

    @Test func playingSpeakerToThisMacTransfers() {
        #expect(OutputMove.decide(from: kitchen, to: mac, sourceState: .playing, thisMacFeed: .local)
            == .transfer(autoPlay: true))
    }

    @Test func pausedTransfersWithoutAutoPlay() {
        #expect(OutputMove.decide(from: kitchen, to: den, sourceState: .paused, thisMacFeed: .local)
            == .transfer(autoPlay: false))
    }

    @Test func loadingTransfersWithAutoPlay() {
        #expect(OutputMove.decide(from: kitchen, to: den, sourceState: .loading, thisMacFeed: .local)
            == .transfer(autoPlay: true))
    }

    @Test func stoppedOnlySelects() {
        #expect(OutputMove.decide(from: kitchen, to: den, sourceState: .stopped, thisMacFeed: .local) == .select)
    }

    @Test func sameOutputOnlySelects() {
        #expect(OutputMove.decide(from: kitchen, to: kitchen, sourceState: .playing, thisMacFeed: .local) == .select)
    }

    @Test func localQueueOnThisMacStaysLocal() {
        #expect(OutputMove.decide(from: mac, to: kitchen, sourceState: .playing, thisMacFeed: .local) == .keepLocal)
    }
}

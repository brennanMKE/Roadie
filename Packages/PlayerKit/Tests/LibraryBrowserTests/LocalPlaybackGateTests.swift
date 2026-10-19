import MusicBackendKit
import Testing
@testable import LibraryBrowser

@Suite struct LocalPlaybackGateTests {
    let speaker = OutputDevice.ID(rawValue: "media_player.kitchen")

    @Test func localFilesPlayOnThisMac() {
        #expect(LocalPlaybackGate.refusal(forLocalFilesOn: OutputDevice.thisMacID) == nil)
    }

    @Test func localFilesAreRefusedOnASpeaker() {
        #expect(LocalPlaybackGate.refusal(forLocalFilesOn: speaker) == LocalPlaybackGate.switchToThisMac)
    }

    @Test func localFilesAreRefusedOnAGroup() {
        let group = OutputDevice(id: OutputDevice.ID(rawValue: "media_player.downstairs"), name: "Downstairs",
                                 kind: .remote, isAvailable: true, isGroup: true)
        #expect(LocalPlaybackGate.refusal(forLocalFilesOn: group.id) == LocalPlaybackGate.switchToThisMac)
    }

    @Test func localSourceIsRefusedOnASpeaker() {
        #expect(LocalPlaybackGate.refusal(source: [.search, .playlists], output: speaker)
            == LocalPlaybackGate.switchToThisMac)
    }

    @Test func remoteSourcePlaysOnASpeaker() {
        #expect(LocalPlaybackGate.refusal(source: [.remoteOutputs], output: speaker) == nil)
    }

    @Test func anySourcePlaysOnThisMac() {
        #expect(LocalPlaybackGate.refusal(source: [.search, .playlists], output: OutputDevice.thisMacID) == nil)
        #expect(LocalPlaybackGate.refusal(source: [.remoteOutputs], output: OutputDevice.thisMacID) == nil)
    }

    @Test func refusalTextMatchesPlayFromLibrary() {
        #expect(LocalPlaybackGate.switchToThisMac == "Switch the output to This Mac to play local files.")
    }
}

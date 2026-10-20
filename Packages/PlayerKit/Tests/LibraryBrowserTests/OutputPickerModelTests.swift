import Foundation
import MusicBackendKit
import MusicBackendStub
import Testing
@testable import LibraryBrowser

/// A flag a `@Sendable` closure can read.
private final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Bool
    init(_ value: Bool) { stored = value }
    var value: Bool {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}

private func device(_ id: String, _ name: String, available: Bool = true, group: Bool = false) -> OutputDevice {
    OutputDevice(id: OutputDevice.ID(rawValue: id), name: name, kind: .remote, isAvailable: available, isGroup: group)
}

@MainActor
struct PlaybackRouterTests {
    @Test func thisMacRoutesToTheLocalBackend() {
        let local = StubMusicBackend(sourceID: "folder")
        let remote = StubMusicBackend(sourceID: "musicAssistant")
        let router = PlaybackRouter(local: local, remote: remote)
        #expect(router.backend(for: OutputDevice.thisMacID) === local)
    }

    @Test func remoteIDsRouteToTheRemoteBackend() {
        let local = StubMusicBackend(sourceID: "folder")
        let remote = StubMusicBackend(sourceID: "musicAssistant")
        let router = PlaybackRouter(local: local, remote: remote)
        #expect(router.backend(for: OutputDevice.ID(rawValue: "ap82fe09484ac9")) === remote)
        #expect(router.backend(for: OutputDevice.ID(rawValue: "group-1")) === remote)
    }

    @Test func defaultFeedIsLocal() {
        let router = PlaybackRouter(local: StubMusicBackend(sourceID: "folder"), remote: StubMusicBackend(sourceID: "musicAssistant"))
        #expect(router.feed.feed == .local)
        #expect(ThisMacFeedState().feed == .local)
    }

    @Test func thisMacFollowsTheFeed() {
        let local = StubMusicBackend(sourceID: "folder")
        let remote = StubMusicBackend(sourceID: "musicAssistant")
        let feed = ThisMacFeedState()
        let router = PlaybackRouter(local: local, remote: remote, feed: feed)
        #expect(router.backend(for: OutputDevice.thisMacID) === local)
        feed.feed = .musicAssistant
        #expect(router.backend(for: OutputDevice.thisMacID) === remote)
        #expect(router.backend(for: OutputDevice.thisMacID, command: .next) === remote)
        feed.feed = .local
        #expect(router.backend(for: OutputDevice.thisMacID, command: .next) === local)
    }

    @Test func feedFollowsMusicAssistantPlayAndStream() {
        #expect(ThisMacFeed.local.after(.musicAssistantPlayRequested) == .musicAssistant)
        #expect(ThisMacFeed.local.after(.streamStarted) == .musicAssistant)
    }

    @Test func failedMusicAssistantPlayReturnsToLocalUnlessStreaming() {
        #expect(ThisMacFeed.musicAssistant.after(.musicAssistantPlayFailed(isStreaming: false)) == .local)
        #expect(ThisMacFeed.musicAssistant.after(.musicAssistantPlayFailed(isStreaming: true)) == .musicAssistant)
    }

    @Test func streamStopReturnsThisMacToTheLocalBackend() {
        let local = StubMusicBackend(sourceID: "folder")
        let remote = StubMusicBackend(sourceID: "musicAssistant")
        let feed = ThisMacFeedState()
        feed.feed = .musicAssistant
        let router = PlaybackRouter(local: local, remote: remote, feed: feed)
        feed.feed = feed.feed.after(.streamStopped)
        #expect(router.backend(for: OutputDevice.thisMacID, command: .next) === local)
    }

    @Test func localPlayTakesThisMacBack() {
        #expect(ThisMacFeed.musicAssistant.after(.localPlayRequested) == .local)
    }

    @Test func volumeAndBalanceOnThisMacStayLocal() {
        let local = StubMusicBackend(sourceID: "folder")
        let remote = StubMusicBackend(sourceID: "musicAssistant")
        let feed = ThisMacFeedState()
        feed.feed = .musicAssistant
        let router = PlaybackRouter(local: local, remote: remote, feed: feed)
        #expect(router.backend(for: OutputDevice.thisMacID, command: .setVolume(0.5)) === local)
        #expect(router.backend(for: OutputDevice.thisMacID, command: .setBalance(-0.2)) === local)
    }

    @Test func speakersAlwaysGoRemote() {
        let local = StubMusicBackend(sourceID: "folder")
        let remote = StubMusicBackend(sourceID: "musicAssistant")
        let router = PlaybackRouter(local: local, remote: remote)
        let speaker = OutputDevice.ID(rawValue: "ap82fe09484ac9")
        for command in [TransportCommand.setVolume(0.3), .setBalance(0.1), .play, .seek(4)] {
            #expect(router.backend(for: speaker, command: command) === remote)
        }
        router.feed.feed = .musicAssistant
        #expect(router.backend(for: speaker) === remote)
    }
}

@MainActor
struct OutputPickerModelTests {
    @Test func listsThisMacFirstThenSpeakersThenGroups() async {
        let remote = StubMusicBackend(sourceID: "musicAssistant")
        await remote.setOutputs([
            device("g2", "Upstairs", group: true), device("s2", "living room"), device("g1", "Everywhere", group: true),
            device("s1", "Kitchen"),
        ])
        let picker = OutputPickerModel(remote: remote, isConnected: { true })
        await picker.refresh()
        #expect(picker.devices.map(\.id.rawValue) == ["this-mac", "s1", "s2", "g1", "g2"])
        #expect(picker.speakers.map(\.name) == ["Kitchen", "living room"])
        #expect(picker.groups.map(\.name) == ["Everywhere", "Upstairs"])
        #expect(picker.hint == nil)
    }

    @Test func notConnectedListsOnlyThisMacWithAHint() async {
        let remote = StubMusicBackend(sourceID: "musicAssistant")
        await remote.setOutputs([device("s1", "Kitchen")])
        let picker = OutputPickerModel(remote: remote, isConnected: { false })
        await picker.refresh()
        #expect(picker.devices == [OutputDevice.thisMac])
        #expect(picker.hint == OutputPickerModel.notConnectedHint)
        #expect(await remote.count(.outputs) == 0)
    }

    @Test func outputsErrorBecomesHint() async {
        let remote = StubMusicBackend(sourceID: "musicAssistant")
        await remote.setError(.unreachable("Can't reach the Music Assistant server."), for: .outputs)
        let picker = OutputPickerModel(remote: remote, isConnected: { true })
        await picker.refresh()
        #expect(picker.devices == [OutputDevice.thisMac])
        #expect(picker.hint == "Can't reach the Music Assistant server.")
    }

    @Test func unavailableDevicesAreListed() async {
        let remote = StubMusicBackend(sourceID: "musicAssistant")
        await remote.setOutputs([device("s1", "Kitchen", available: false)])
        let picker = OutputPickerModel(remote: remote, isConnected: { true })
        await picker.refresh()
        #expect(picker.speakers.count == 1)
        #expect(picker.speakers.first?.isAvailable == false)
    }

    @Test func reconcileFallsBackToThisMacWhenTheSelectionDisappears() async {
        let remote = StubMusicBackend(sourceID: "musicAssistant")
        await remote.setOutputs([device("s1", "Kitchen")])
        let picker = OutputPickerModel(remote: remote, isConnected: { true })
        await picker.refresh()
        let kitchen = OutputDevice.ID(rawValue: "s1")
        #expect(picker.reconcile(selected: kitchen) == kitchen)
        await remote.setOutputs([device("s2", "Den")])
        await picker.refresh()
        #expect(picker.reconcile(selected: kitchen) == OutputDevice.thisMacID)
        #expect(picker.reconcile(selected: OutputDevice.thisMacID) == OutputDevice.thisMacID)
    }

    @Test func refreshNeverConnects() async {
        let remote = StubMusicBackend(sourceID: "musicAssistant")
        let connected = Flag(false)
        let picker = OutputPickerModel(remote: remote, isConnected: { connected.value })
        await picker.refresh()
        connected.value = true
        await picker.refresh()
        #expect(await remote.isConnected == false)
        #expect(await remote.count(.connect) == 0)
        #expect(await remote.count(.outputs) == 1)
    }
}

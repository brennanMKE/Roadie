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

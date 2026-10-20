import Foundation
import MusicBackendKit
import MusicBackendStub
import Testing
@testable import LibraryBrowser

@MainActor
struct LibraryFallbackControllerTests {
    /// Server is down when the Library window connects: the fallback moves to the folder and schedules a retry.
    private func enterFallback(_ f: FallbackFixture) async {
        f.fallback.start()
        await f.server.setError(.unreachable("down"), for: .connect)
        f.controller.library.appeared()
        #expect(await waitFor { f.controller.selectedID == "folder" })
        #expect(await waitFor { f.fallback.timerCount == 1 && f.clock.sleeperCount == 1 })
    }

    @Test func startActivatesTheFolderWithoutIOWhenServerIsNotSetUp() async {
        let f = makeFallback(serverConfigured: false)
        defer { f.cleanUp() }
        f.fallback.start()
        #expect(f.controller.selectedID == "folder")
        #expect(f.controller.preferredID == "server")
        #expect(f.defaults.string(forKey: LibrarySourceController.defaultsKey) == nil)
        #expect(await f.server.count(.connect) == 0)
        #expect(await f.folder.count(.connect) == 0)
        #expect(f.notices.notices == [FallbackNotice(text: "Using Local Folder", detail: "Server isn't set up")])
        #expect(f.fallback.timerCount == 0)
        #expect(f.fallback.probeCount == 0)
        #expect(f.folderCheck.count == 0)
    }

    @Test func aFailedLibraryConnectFallsBackAndSchedulesARetry() async {
        let f = makeFallback()
        defer { f.cleanUp() }
        await enterFallback(f)
        #expect(await f.server.count(.connect) == 1)  // the window's connect was the probe
        #expect(f.fallback.status.reason == .unreachable("down"))
        #expect(f.fallback.status.activeID == "folder")
        #expect(f.notices.notices.last?.text == "Using Local Folder")
        #expect(f.notices.notices.last?.detail == "Server can't be reached")
        #expect(f.defaults.string(forKey: LibrarySourceController.defaultsKey) == nil)
        #expect(!(await f.server.calls.contains(.disconnect)))
    }

    @Test func theRetryTimerBacksOffAndRestoresServerWhenItAnswers() async {
        let f = makeFallback()
        defer { f.cleanUp() }
        await enterFallback(f)
        f.clock.advance(by: .seconds(5))
        #expect(await waitFor { await f.server.count(.connect) == 2 })
        #expect(await waitFor { f.fallback.policy.health["server"]?.hasTimer == true && f.clock.sleeperCount == 1 })
        f.clock.advance(by: .seconds(10))
        #expect(await waitFor { await f.server.count(.connect) == 3 })
        #expect(await waitFor { f.fallback.policy.health["server"]?.hasTimer == true && f.clock.sleeperCount == 1 })
        await f.server.setError(nil, for: .connect)
        f.clock.advance(by: .seconds(20))
        #expect(await waitFor { f.controller.selectedID == "server" })
        #expect(f.fallback.status.reason == nil)
        #expect(f.notices.notices.last == FallbackNotice(text: "Back on Server", detail: nil))
        #expect(await waitFor { f.fallback.timerCount == 0 })
        #expect(await f.server.count(.transport) == 0)
        #expect(await f.folder.count(.transport) == 0)
    }

    @Test func aBrowseFailureOnTheActiveSourceIsConfirmedBeforeFallingBack() async {
        let f = makeFallback()
        defer { f.cleanUp() }
        f.fallback.start()
        let library = f.controller.library
        library.appeared()
        #expect(await waitFor { library.connection == .connected && library.artists.phase == .loaded })
        // A lost page that is not a reachability problem does nothing.
        await f.server.setError(.notFound(MediaID(.artist, "gone")), for: .artists)
        library.refresh()
        #expect(await waitFor { if case .failed = library.artists.phase { true } else { false } })
        #expect(f.fallback.probeCount == 0)
        #expect(f.controller.selectedID == "server")
        #expect(await f.server.count(.connect) == 1)
        // An unreachable one is confirmed by one more connect, then the folder takes over.
        await f.server.setError(.unreachable("x"), for: .artists)
        await f.server.setError(.unreachable("x"), for: .connect)
        library.refresh()
        #expect(await waitFor { f.controller.selectedID == "folder" })
        #expect(await f.server.count(.connect) == 2)
        #expect(f.folderCheck.count == 1)
    }

    @Test func aPlayFailureReportedByTheAppFallsBackToo() async {
        let f = makeFallback()
        defer { f.cleanUp() }
        f.fallback.start()
        await f.server.setError(.unreachable("x"), for: .connect)
        f.fallback.report(MusicBackendError.notFound(MediaID(.track, "t")), from: "server")
        f.fallback.report(MusicBackendError.unreachable("x"), from: "folder")  // not the active source
        f.fallback.report(CancellationError(), from: "server")
        #expect(f.fallback.probeCount == 0)
        #expect(f.controller.selectedID == "server")
        f.fallback.report(MusicBackendError.unreachable("x"), from: "server")
        #expect(await waitFor { f.controller.selectedID == "folder" })
        #expect(f.notices.notices.last?.text == "Using Local Folder")
    }

    @Test func userSelectionPersistsAndStopsRetrying() async {
        let f = makeFallback()
        defer { f.cleanUp() }
        await enterFallback(f)
        let noticeCount = f.notices.notices.count
        f.fallback.userSelected("folder")
        #expect(f.defaults.string(forKey: LibrarySourceController.defaultsKey) == "folder")
        #expect(f.controller.preferredID == "folder")
        #expect(f.fallback.timerCount == 0)
        #expect(await waitFor { f.clock.sleeperCount == 0 })
        #expect(f.fallback.status.reason == nil)
        #expect(f.notices.notices.count == noticeCount)
    }

    @Test func settingsChangedProbesANewlyConfiguredPreferred() async {
        let f = makeFallback(serverConfigured: false)
        defer { f.cleanUp() }
        f.fallback.start()
        f.sources.serverConfigured.value = true
        await f.server.gate(.connect)
        f.fallback.settingsChanged()
        f.fallback.settingsChanged()
        #expect(await waitFor { await f.server.suspendedCount == 1 })
        #expect(await f.server.count(.connect) == 1)  // coalesced
        await f.server.release(.connect)
        #expect(await waitFor { f.controller.selectedID == "server" })
        #expect(f.fallback.status.reason == nil)
        #expect(f.notices.notices.last?.text == "Back on Server")
    }

    @Test func aFolderThatCannotBeReadIsSkipped() async {
        let f = makeFallback()
        defer { f.cleanUp() }
        f.folderCheck.error = .unreachable("The music folder \u{201C}X\u{201D} can't be read.")
        f.fallback.start()
        await f.server.setError(.unreachable("down"), for: .connect)
        f.controller.library.appeared()
        #expect(await waitFor { f.folderCheck.count == 1 })
        #expect(await waitFor { f.fallback.probeCount == 0 })
        #expect(f.controller.selectedID == "server")
        #expect(f.fallback.status.reason == .unreachable("down"))
        #expect(f.fallback.timerCount == 0)
        #expect(await waitFor {
            if case .failed(_, let needsSettings) = f.controller.library.connection { !needsSettings } else { false }
        })
    }

    @Test func fallbackNeverWritesDefaultsOrDisconnectsABackend() async {
        let f = makeFallback()
        defer { f.cleanUp() }
        await enterFallback(f)
        await f.server.setError(nil, for: .connect)
        f.clock.advance(by: .seconds(5))
        #expect(await waitFor { f.controller.selectedID == "server" })
        #expect(f.defaults.dictionaryRepresentation()[LibrarySourceController.defaultsKey] == nil)
        #expect(!(await f.server.calls.contains(.disconnect)))
        #expect(!(await f.folder.calls.contains(.disconnect)))
        #expect(await f.server.isConnected)
    }

    @Test func stopCancelsTimersAndProbes() async {
        let f = makeFallback()
        defer { f.cleanUp() }
        f.fallback.start()
        await f.server.gate(.connect)
        f.fallback.report(MusicBackendError.unreachable("x"), from: "server")
        #expect(await waitFor { await f.server.suspendedCount == 1 })
        f.fallback.stop()
        #expect(await waitFor { await f.server.cancelledCount == 1 })
        #expect(f.fallback.timerCount == 0)
        #expect(f.fallback.probeCount == 0)
        #expect(f.clock.sleeperCount == 0)
        #expect(f.controller.selectedID == "server")
    }

    @Test func statusFollowsTheSwitch() async {
        let f = makeFallback()
        defer { f.cleanUp() }
        #expect(f.fallback.status.activeName == "Server")
        await enterFallback(f)
        #expect(f.fallback.status.activeName == "Local Folder")
        await f.server.setError(nil, for: .connect)
        f.clock.advance(by: .seconds(5))
        #expect(await waitFor { f.fallback.status.activeName == "Server" })
        #expect(f.fallback.status.preferredName == "Server")
    }
}

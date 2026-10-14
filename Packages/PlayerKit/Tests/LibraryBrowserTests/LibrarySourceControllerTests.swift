import CoreGraphics
import Foundation
import ImageIO
import MusicBackendKit
import MusicBackendStub
import Testing
@testable import LibraryBrowser

@MainActor
struct LibrarySourceSelectionTests {
    private func sources() -> [LibrarySource] {
        [
            LibrarySource(backend: StubMusicBackend(sourceID: "plex", displayName: "Plex"), isConfigured: { true }),
            LibrarySource(backend: StubMusicBackend(sourceID: "folder", displayName: "Local Folder"), isConfigured: { true }),
        ]
    }

    @Test func storedChoiceWinsWhenAvailable() {
        #expect(LibrarySourceSelection.resolve(stored: "folder", available: sources(), fallback: "plex") == "folder")
    }

    @Test func missingOrUnknownStoredChoiceFallsBackToTheDefault() {
        #expect(LibrarySourceSelection.resolve(stored: nil, available: sources(), fallback: "plex") == "plex")
        #expect(LibrarySourceSelection.resolve(stored: "musicAssistant", available: sources(), fallback: "folder") == "folder")
    }

    @Test func anUnavailableDefaultFallsBackToTheFirstSource() {
        #expect(LibrarySourceSelection.resolve(stored: nil, available: sources(), fallback: "musicAssistant") == "plex")
    }
}

private func tinyPNG() -> Data {
    let context = CGContext(
        data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.8, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
    let data = NSMutableData()
    let destination = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, context.makeImage()!, nil)
    CGImageDestinationFinalize(destination)
    return data as Data
}

/// Collects a now-playing stream's titles (nil title for an idle snapshot) on the main actor.
@MainActor
private final class TitleLog {
    var titles: [String?] = []
    var task: Task<Void, Never>?

    init(_ stream: AsyncStream<NowPlaying>) {
        task = Task { [weak self] in
            for await snapshot in stream { self?.titles.append(snapshot.title) }
        }
    }
    var last: String? { titles.last ?? nil }
}

@MainActor
struct LibrarySourceControllerTests {
    @Test func initSelectsTheStoredSource() {
        let f = makeSources(stored: "folder")
        defer { f.cleanUp() }
        let c = f.controller
        #expect(c.selectedID == "folder")
        #expect(c.preferredID == "folder")
        #expect(c.backend.sourceID == "folder")
        #expect(c.library.backend.sourceID == "folder")
        #expect(c.selected.displayName == "Local Folder")
        #expect(c.sources.map(\.id) == ["plex", "folder"])
    }

    @Test func initUsesTheDefaultOnAFreshInstallWithoutWritingIt() {
        let f = makeSources()
        defer { f.cleanUp() }
        #expect(f.controller.selectedID == "plex")
        #expect(f.defaults.string(forKey: LibrarySourceController.defaultsKey) == nil)
        #expect(f.controller.generation == 0)
    }

    @Test func selectPersistsTheChoiceAndBumpsTheGeneration() {
        let f = makeSources()
        defer { f.cleanUp() }
        #expect(f.controller.select("folder") == true)
        #expect(f.defaults.string(forKey: LibrarySourceController.defaultsKey) == "folder")
        #expect(f.controller.generation == 1)
        #expect(f.controller.selected.id == "folder")
        #expect(f.controller.preferredID == "folder")
    }

    @Test func selectRebuildsTheBrowserModelAndTheArtworkCache() async {
        let f = makeSources()
        defer { f.cleanUp() }
        let c = f.controller
        let ref = ArtworkRef(rawValue: "art-1")
        await f.plex.setArtwork(tinyPNG(), for: ref)
        c.library.appeared()
        #expect(await waitFor { c.library.connection == .connected && c.library.artists.phase == .loaded })
        #expect(await c.artwork.image(for: ref) != nil)
        let old = c.library
        let oldArt = c.artwork
        #expect(c.select("folder"))
        #expect(c.library !== old)
        #expect(c.library.connection == .idle)
        #expect(c.library.artists.items.isEmpty)
        #expect(c.library.backend.sourceID == "folder")
        #expect(c.artwork !== oldArt)
        #expect(await c.artwork.cached(ref) == nil)
        #expect(await c.artwork.statistics.count == 0)
    }

    @Test func selectTheSameSourceIsANoOp() {
        let f = makeSources()
        defer { f.cleanUp() }
        let old = f.controller.library
        #expect(f.controller.select("plex") == false)
        #expect(f.controller.library === old)
        #expect(f.controller.generation == 0)
        #expect(f.defaults.string(forKey: LibrarySourceController.defaultsKey) == nil)
    }

    @Test func selectAnUnknownSourceIsRefused() {
        let f = makeSources()
        defer { f.cleanUp() }
        let old = f.controller.library
        #expect(f.controller.select("musicAssistant") == false)
        #expect(f.controller.library === old)
        #expect(f.controller.selectedID == "plex")
        #expect(f.controller.generation == 0)
    }

    @Test func selectCancelsTheOldBrowsersInFlightWork() async {
        let f = makeSources()
        defer { f.cleanUp() }
        await f.plex.gate(.artists)
        let old = f.controller.library
        old.appeared()
        #expect(await waitFor { await f.plex.suspendedCount == 1 })
        f.controller.select("folder")
        #expect(await waitFor { await f.plex.cancelledCount == 1 })
        #expect(old.artists.phase != .loading)
    }

    @Test func selectNeverConnectsOrDisconnectsABackend() async {
        let f = makeSources()
        defer { f.cleanUp() }
        f.controller.library.appeared()
        #expect(await waitFor { f.controller.library.connection == .connected })
        f.controller.select("folder")
        let plexCalls = await f.plex.calls
        #expect(!plexCalls.contains(.disconnect))
        #expect(await f.folder.count(.connect) == 0)
        #expect(await f.plex.isConnected)
    }

    @Test func aRebuiltModelConnectsWhenAppearedAgain() async {
        let f = makeSources()
        defer { f.cleanUp() }
        f.controller.select("folder")
        f.controller.library.appeared()
        #expect(await waitFor { await f.folder.count(.connect) == 1 && f.controller.library.artists.items.count == 3 })
    }

    @Test func nowPlayingFollowsTheActiveBackendAcrossASwitch() async {
        let f = makeSources()
        defer { f.cleanUp() }
        let log = TitleLog(f.controller.nowPlaying(on: OutputDevice.thisMacID))
        defer { log.task?.cancel() }
        #expect(await waitFor { log.titles.count == 1 })
        #expect(log.titles.first == .some(nil))
        #expect(await waitFor { await f.plex.emit(snapshot(title: "A")); return log.last == "A" })
        await f.folder.emit(snapshot(title: "B"))
        let before = log.titles.count
        f.controller.select("folder")
        #expect(await waitFor { log.last == "B" })
        // The switch forwards the new backend's current snapshot, never an idle one.
        #expect(!log.titles[before...].contains { $0 == nil })
        #expect(f.controller.nowPlayingSubscriberCount == 1)
        await f.folder.emit(snapshot(title: "C"))
        #expect(await waitFor { log.last == "C" })
        await f.plex.emit(snapshot(title: "D"))
        try? await Task.sleep(for: .milliseconds(30))
        #expect(!log.titles.contains("D"))
        #expect(f.controller.nowPlayingSubscriberCount == 1)
    }

    @Test func cancellingTheNowPlayingSubscriptionEndsIt() async {
        let f = makeSources()
        defer { f.cleanUp() }
        let log = TitleLog(f.controller.nowPlaying(on: OutputDevice.thisMacID))
        #expect(await waitFor { f.controller.nowPlayingSubscriberCount == 1 && log.titles.count == 1 })
        log.task?.cancel()
        #expect(await waitFor { f.controller.nowPlayingSubscriberCount == 0 })
        f.controller.select("folder")
        #expect(f.controller.generation == 1)
    }

    @Test func twoSubscriptionsAreBothRePointed() async {
        let f = makeSources()
        defer { f.cleanUp() }
        let one = TitleLog(f.controller.nowPlaying(on: OutputDevice.thisMacID))
        let two = TitleLog(f.controller.nowPlaying(on: OutputDevice.thisMacID))
        defer { one.task?.cancel(); two.task?.cancel() }
        #expect(await waitFor { one.titles.count == 1 && two.titles.count == 1 })
        await f.folder.emit(snapshot(title: "B"))
        f.controller.select("folder")
        #expect(await waitFor { one.last == "B" && two.last == "B" })
    }

    @Test func isConfiguredIsReadFromTheSource() {
        let f = makeSources()
        defer { f.cleanUp() }
        #expect(f.controller.sources[1].isConfigured())
        f.folderConfigured.value = false
        #expect(!f.controller.sources[1].isConfigured())
        #expect(f.controller.sources[0].isConfigured())
    }

    // MARK: #0067 amendments

    @Test func selectWithoutPersistingKeepsThePreferredChoice() {
        let f = makeSources()
        defer { f.cleanUp() }
        #expect(f.controller.select("folder", persist: false))
        #expect(f.controller.selectedID == "folder")
        #expect(f.controller.preferredID == "plex")
        #expect(f.defaults.string(forKey: LibrarySourceController.defaultsKey) == nil)
        #expect(f.controller.generation == 1)
        #expect(f.controller.select("folder", persist: true))
        #expect(f.controller.preferredID == "folder")
        #expect(f.defaults.string(forKey: LibrarySourceController.defaultsKey) == "folder")
        #expect(f.controller.generation == 1)
    }

    @Test func theFailureHookIsInstalledOnEveryBrowserModel() async {
        let f = makeSources()
        defer { f.cleanUp() }
        var reports: [String] = []
        f.controller.onBackendFailure = { id, error, phase in reports.append("\(id) \(error) \(phase)") }
        await f.plex.setError(.unreachable("down"), for: .connect)
        f.controller.library.appeared()
        #expect(await waitFor { reports.count == 1 })
        #expect(reports[0] == "plex unreachable(\"down\") connect")
        f.controller.select("folder")
        await f.folder.setError(.unreachable("gone"), for: .artists)
        f.controller.library.appeared()
        #expect(await waitFor { reports.count == 2 })
        #expect(reports[1] == "folder unreachable(\"gone\") browse")
    }
}

import AudioCore
import Foundation
import MusicBackendKit
import VisualizationKit
import XCTest

@testable import Roadie

/// The song title on track change and on T, the F2–F5 readouts and the F1 help card (#0239), on a manual clock.
@MainActor
final class VisualizationTitleTests: PlayerModelTestCase {
    private var now: TimeInterval = 0
    /// The player model, kept alive for the test (the visualization holds it weakly), and its defaults.
    private var model: PlayerModel?
    private var defaults: UserDefaults?

    private func openVis(_ setUp: (UserDefaults) -> Void = { _ in }) throws -> VisualizationModel {
        var configuration = try testConfiguration()
        configuration.visRenderer = "classic"
        configuration.visSeed = 1
        setUp(configuration.defaults)
        let model = makeModel(configuration)
        self.model = model
        defaults = configuration.defaults
        let vis = model.visualization
        vis.currentTime = { [unowned self] in self.now }
        now = 0
        vis.open()
        vis.setVisible(true)
        return vis
    }

    func testATrackChangeStartsATitleShow() throws {
        let vis = try openVis()
        vis.noteTrack(identity: "one", text: "The Band – Song One")
        XCTAssertEqual(vis.songTitleShowCount, 0)
        vis.noteTrack(identity: "two", text: "The Band – Song Two")
        XCTAssertEqual(vis.songTitleShowCount, 1)
        XCTAssertEqual(vis.songTitle?.text, "The Band – Song Two")
        // The same track again (a state change) shows nothing new.
        vis.noteTrack(identity: "two", text: "The Band – Song Two")
        XCTAssertEqual(vis.songTitleShowCount, 1)
    }

    func testTheFirstTrackAfterOpeningDoesNotShow() throws {
        let vis = try openVis()
        vis.noteTrack(identity: nil, text: nil)
        vis.noteTrack(identity: "one", text: "Song One")
        XCTAssertEqual(vis.songTitleShowCount, 0)
        XCTAssertNil(vis.songTitle)
        // Closed: nothing; reopening starts over.
        vis.close()
        vis.noteTrack(identity: "two", text: "Song Two")
        XCTAssertEqual(vis.songTitleShowCount, 0)
    }

    func testTheSettingTurnsItOff() throws {
        let vis = try openVis()
        vis.updateSettings { $0.songTitleOnTrackChange = false }
        vis.noteTrack(identity: "one", text: "Song One")
        vis.noteTrack(identity: "two", text: "Song Two")
        XCTAssertEqual(vis.songTitleShowCount, 0)
    }

    func testTShowsItOnDemand() throws {
        let vis = try openVis()
        vis.perform(.showSongTitle)
        XCTAssertEqual(vis.songTitleShowCount, 1)
        XCTAssertEqual(vis.songTitle?.text, "Nothing is playing")
        vis.perform(.showSongTitle)
        XCTAssertEqual(vis.songTitleShowCount, 2)
        XCTAssertEqual(vis.songTitle?.id, 2, "a new show replaces the running one")
    }

    func testTitleWithoutArtist() {
        XCTAssertEqual(VisualizationModel.songTitleText(title: "Song One", artist: "The Band"), "The Band – Song One")
        XCTAssertEqual(VisualizationModel.songTitleText(title: "Song One", artist: nil), "Song One")
        XCTAssertEqual(VisualizationModel.songTitleText(title: "Song One", artist: ""), "Song One")
        XCTAssertNil(VisualizationModel.songTitleText(title: nil, artist: "The Band"))
    }

    func testReadoutsPersist() throws {
        let vis = try openVis()
        vis.perform(.toggleReadout(.time))
        vis.perform(.toggleReadout(.fps))
        XCTAssertEqual(vis.settings.readouts, [.time, .fps])
        let defaults = try XCTUnwrap(defaults)
        XCTAssertEqual(defaults.stringArray(forKey: VisualizationSettings.Key.readouts), ["time", "fps"])
        XCTAssertEqual(VisualizationSettings.load(from: defaults).readouts, [.time, .fps])
        vis.perform(.toggleReadout(.time))
        vis.perform(.toggleReadout(.fps))
        XCTAssertEqual(vis.settings.readouts, [])
        XCTAssertEqual(defaults.stringArray(forKey: VisualizationSettings.Key.readouts), [])
        // The menu shows ✓ per readout.
        vis.perform(.toggleReadout(.preset))
        let menu = VisualizationContextMenu.make(model: vis)
        let preset = try XCTUnwrap(menu.items.first { $0.title == "Preset Name" })
        XCTAssertEqual(preset.state, .on)
        XCTAssertTrue(preset.isEnabled)
        XCTAssertEqual(menu.items.first { $0.title == "Frame Rate" }?.state, .off)
    }

    func testBottomReadoutsHideWhileTheCardIsVisible() {
        let all = Set(VisReadout.allCases)
        for readout in VisReadout.allCases {
            XCTAssertTrue(VisualizationModel.showsReadout(readout, on: all, overlayVisible: false), "\(readout)")
            XCTAssertFalse(VisualizationModel.showsReadout(readout, on: [], overlayVisible: false), "\(readout)")
        }
        XCTAssertTrue(VisualizationModel.showsReadout(.fps, on: all, overlayVisible: true))
        XCTAssertFalse(VisualizationModel.showsReadout(.title, on: all, overlayVisible: true))
        XCTAssertFalse(VisualizationModel.showsReadout(.time, on: all, overlayVisible: true))
        XCTAssertFalse(VisualizationModel.showsReadout(.preset, on: all, overlayVisible: true))
    }

    func testHelpHoldsTheOverlayAndSuspendsAutoAdvance() throws {
        let vis = try openVis()
        XCTAssertFalse(vis.clock.isSuspended)
        vis.perform(.help)
        XCTAssertTrue(vis.isHelpOpen)
        XCTAssertTrue(vis.overlay.holds.contains(.help))
        XCTAssertTrue(vis.clock.isSuspended)
        // Esc closes it first.
        vis.perform(.escape)
        XCTAssertFalse(vis.isHelpOpen)
        XCTAssertFalse(vis.overlay.holds.contains(.help))
        XCTAssertFalse(vis.clock.isSuspended)
        vis.perform(.help)
        vis.perform(.help)
        XCTAssertFalse(vis.isHelpOpen, "F1 again closes it")
    }

    // MARK: #0248

    /// Closing the window closes help and the preset list, with their holds and suspensions.
    func testClosingClosesHelpAndTheList() throws {
        let vis = try openVis()
        vis.perform(.help)
        vis.openList()
        XCTAssertTrue(vis.isHelpOpen)
        XCTAssertTrue(vis.isListOpen)
        vis.close()
        XCTAssertFalse(vis.isHelpOpen)
        XCTAssertFalse(vis.isListOpen)
        XCTAssertFalse(vis.overlay.holds.contains(.help))
        XCTAssertFalse(vis.overlay.holds.contains(.browser))
        XCTAssertFalse(vis.suspensions.contains(.help))
        XCTAssertFalse(vis.suspensions.contains(.list))
        vis.open()
        XCTAssertFalse(vis.isHelpOpen, "reopening shows no help card")
        XCTAssertFalse(vis.isListOpen)
    }

    /// Repeated opens leave one live track observation: a track change re-arms one chain, not one per open.
    func testRepeatedOpensKeepOneTrackObservation() async throws {
        let vis = try openVis()
        vis.close()
        vis.open()
        vis.close()
        vis.open()
        let player = try XCTUnwrap(model).player
        let tracks = (0..<2).map { i in
            Track(
                title: "Tone \(i)", artist: "Artist", duration: 61,
                source: .file(URL(fileURLWithPath: "/nonexistent/roadie-tests/\(i).mp3")))
        }
        // Three opens armed three observations; a change fires them all, and only the latest open's re-arms.
        XCTAssertGreaterThan(vis.titleState.armedTrackObservations, 1, "stale ones stay armed until a change")
        player.restoreQueue(tracks, currentIndex: 0, repeatMode: .off, isShuffled: false)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(vis.titleState.armedTrackObservations, 1, "one live chain")
        // It stays live: the next change (`restoreQueue` only fills an empty queue) still reaches `noteTrack`.
        player.clearQueue()
        player.restoreQueue(tracks, currentIndex: 1, repeatMode: .off, isShuffled: false)
        try await waitUntil("the second track's identity") { vis.titleState.trackIdentity == "queue:\(tracks[1].id)" }
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(vis.titleState.armedTrackObservations, 1, "still one live chain")
    }

    /// A Music Assistant snapshot whose artist arrives after its title is the same track.
    func testALateArtistKeepsTheTrackIdentity() {
        let item = MediaID(.track, "library://track/42")
        let early = NowPlaying(output: OutputDevice.thisMacID, state: .playing, item: item, title: "Song One")
        var late = early
        late.artist = "The Band"
        XCTAssertNotNil(VisualizationModel.trackIdentity(nowPlaying: early, current: nil))
        XCTAssertEqual(
            VisualizationModel.trackIdentity(nowPlaying: early, current: nil),
            VisualizationModel.trackIdentity(nowPlaying: late, current: nil))
        // With no id, the title alone; nothing at all is nil.
        let bare = NowPlaying(output: OutputDevice.thisMacID, state: .playing, title: "Song One", artist: "The Band")
        XCTAssertEqual(VisualizationModel.trackIdentity(nowPlaying: bare, current: nil), "title:Song One")
        XCTAssertNil(VisualizationModel.trackIdentity(nowPlaying: .idle(on: OutputDevice.thisMacID), current: nil))
    }

    /// The local queue: the queue entry's id, whatever the snapshot says.
    func testCurrentTrackIdentityForALocalTrack() throws {
        let vis = try openVis()
        XCTAssertNil(vis.currentTrackIdentity, "nothing queued")
        let player = try XCTUnwrap(model).player
        let track = Track(
            title: "Tone A", artist: "Artist", duration: 61,
            source: .file(URL(fileURLWithPath: "/nonexistent/roadie-tests/a.mp3")))
        player.restoreQueue([track], currentIndex: 0, repeatMode: .off, isShuffled: false)
        XCTAssertEqual(vis.currentTrackIdentity, "queue:\(track.id)")
    }

    /// A Music Assistant speaker (scripted fixtures): the snapshot's item id.
    func testCurrentTrackIdentityForAMusicAssistantTrack() async throws {
        let model = try makeModel(scenario: .queueLoaded)
        let speaker = try await selectSpeakerWithQueue(model)
        try await waitUntil("the speaker plays") {
            model.nowPlaying.output == speaker && model.nowPlaying.item != nil
        }
        let item = try XCTUnwrap(model.nowPlaying.item)
        let vis = model.visualization
        vis.open()
        XCTAssertEqual(vis.currentTrackIdentity, "item:\(item)")
        vis.close()
    }
}

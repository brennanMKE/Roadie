import AudioCore
import Foundation
import MusicBackendKit
import VisualizationKit
import XCTest

@testable import Roadie

/// The visualization window's song overlay (#0238): its content and its idle hiding, on a manual clock.
@MainActor
final class VisualizationOverlayTests: PlayerModelTestCase {
    private var now: TimeInterval = 0

    private func track(_ title: String, artist: String = "The Band", album: String? = "The Album") -> Track {
        Track(
            title: title, artist: artist, album: album, duration: 320,
            source: .file(URL(fileURLWithPath: "/tmp/\(title).mp3")))
    }

    private func content(
        _ nowPlaying: NowPlaying, current: Track? = nil, next: Track? = nil,
        audio: VisualizationModel.AudioSource = .local
    ) -> VisualizationOverlayContent {
        .make(
            nowPlaying: nowPlaying, current: current, next: next, outputName: "This Mac", volume: 0.72,
            audioSource: audio, elapsed: 72, showsRemaining: false)
    }

    private func openVis(_ configure: (inout RoadieConfiguration) -> Void = { _ in }) throws -> VisualizationModel {
        var configuration = try testConfiguration()
        configuration.visRenderer = "classic"
        configure(&configuration)
        let model = makeModel(configuration)
        let vis = model.visualization
        vis.currentTime = { [unowned self] in self.now }
        now = 0
        vis.open()
        vis.setVisible(true)
        return vis
    }

    func testOverlayTextFollowsTheCurrentTrack() {
        let playing = NowPlaying(
            output: OutputDevice.thisMacID, state: .playing, title: "Song One", artist: "The Band", album: "The Album",
            duration: 320)
        let c = content(playing, next: track("Song Two"))
        XCTAssertEqual(c.title, "Song One")
        XCTAssertEqual(c.artistLine, "The Band — The Album")
        XCTAssertEqual(c.next, "Next: Song Two")
        XCTAssertEqual(c.stateLabel, "Playing")
        XCTAssertEqual(c.timeLabel, "Elapsed 1:12 of 5:20")
        XCTAssertEqual(c.outputLine, "This Mac · Volume 72%")
        XCTAssertNil(c.note)
        XCTAssertFalse(c.showsNoAudioBadge)
        // From the queue when the snapshot has no title; no album leaves just the artist.
        let fromQueue = content(
            NowPlaying(output: OutputDevice.thisMacID, state: .paused), current: track("Queued", album: nil))
        XCTAssertEqual(fromQueue.title, "Queued")
        XCTAssertEqual(fromQueue.artistLine, "The Band")
        XCTAssertEqual(fromQueue.stateLabel, "Paused")
    }

    func testOverlayWithNothingPlaying() {
        let c = content(.idle(on: OutputDevice.thisMacID), next: track("Song Two"))
        XCTAssertEqual(c.title, "Nothing is playing")
        XCTAssertNil(c.artistLine)
        XCTAssertNil(c.next)
        XCTAssertNil(c.elapsed)
        XCTAssertNil(c.timeLabel)
    }

    func testRemoteOutputAddsTheNoteAndTheBadge() {
        let playing = NowPlaying(output: OutputDevice.ID(rawValue: "kitchen"), state: .playing, title: "Song One")
        let c = content(playing, audio: .remote("Kitchen"))
        XCTAssertEqual(c.note, "Playing on Kitchen. The visualization needs the music playing on this Mac.")
        XCTAssertTrue(c.showsNoAudioBadge)
    }

    func testPausingHoldsTheOverlay() throws {
        let vis = try openVis()
        vis.syncOverlayPlaybackHold(state: .playing)
        vis.showOverlay()
        now = 3.5
        vis.tickOverlay()
        XCTAssertFalse(vis.overlay.isOverlayVisible, "still up after the idle time")
        vis.syncOverlayPlaybackHold(state: .paused)
        XCTAssertTrue(vis.overlay.isOverlayVisible, "pausing didn't bring it back")
        now = 20
        vis.tickOverlay()
        XCTAssertTrue(vis.overlay.isOverlayVisible, "hid while paused")
        vis.syncOverlayPlaybackHold(state: .playing)
        now = 22
        vis.tickOverlay()
        XCTAssertTrue(vis.overlay.isOverlayVisible, "hid before the idle time after playing again")
        now = 23.5
        vis.tickOverlay()
        XCTAssertFalse(vis.overlay.isOverlayVisible, "didn't hide after playing again")
        vis.stopOverlayTimer()
    }

    func testEnteringFullScreenShowsTheOverlay() throws {
        let vis = try openVis()
        vis.syncOverlayPlaybackHold(state: .playing)
        vis.showOverlay()
        now = 5
        vis.tickOverlay()
        XCTAssertFalse(vis.overlay.isOverlayVisible)
        vis.setFullScreen(true)
        XCTAssertTrue(vis.overlay.isOverlayVisible, "entering full screen didn't show the overlay")
        vis.stopOverlayTimer()
    }

    func testThePresetListHoldsTheOverlay() throws {
        let vis = try openVis()
        vis.syncOverlayPlaybackHold(state: .playing)
        vis.showOverlay()
        vis.openList()
        now = 10
        vis.tickOverlay()
        XCTAssertTrue(vis.overlay.isOverlayVisible, "hid while the preset list was open")
        vis.closeList()
        now = 14
        vis.tickOverlay()
        XCTAssertFalse(vis.overlay.isOverlayVisible, "didn't hide after the list closed")
        vis.stopOverlayTimer()
    }

    func testThePointerOutsideNeverHidesTheCursor() throws {
        let vis = try openVis()
        var inside = false
        var hides = 0
        vis.isPointerInside = { inside }
        vis.hideCursor = { hides += 1 }
        vis.syncOverlayPlaybackHold(state: .playing)
        vis.showOverlay()
        now = 5
        vis.tickOverlay()
        XCTAssertFalse(vis.overlay.isOverlayVisible, "the overlay should still hide on time")
        XCTAssertFalse(vis.overlay.isCursorHidden, "the cursor hid with the pointer outside")
        XCTAssertEqual(hides, 0)
        // Back over the picture: it hides with the overlay again.
        inside = true
        vis.overlayPointerMoved(inside: true)
        now = 10
        vis.tickOverlay()
        XCTAssertTrue(vis.overlay.isCursorHidden)
        XCTAssertEqual(hides, 1)
        vis.stopOverlayTimer()
    }

    func testTheIdleSettingAppliesToTheRunningOverlay() throws {
        let vis = try openVis()
        vis.syncOverlayPlaybackHold(state: .playing)
        vis.showOverlay()
        vis.updateSettings { $0.overlayIdleSeconds = 10 }
        XCTAssertEqual(vis.overlay.idleTimeout, 10)
        now = 5
        vis.tickOverlay()
        XCTAssertTrue(vis.overlay.isOverlayVisible, "hid before the new idle time")
        now = 10.5
        vis.tickOverlay()
        XCTAssertFalse(vis.overlay.isOverlayVisible, "didn't hide after the new idle time")
        vis.updateSettings { $0.overlayIdleSeconds = 0 }
        XCTAssertTrue(vis.overlay.isOverlayVisible, "Never didn't bring the overlay back")
        now = 1000
        vis.tickOverlay()
        XCTAssertTrue(vis.overlay.isOverlayVisible, "Never still hid the overlay")
        vis.stopOverlayTimer()
    }

    func testIdleOverrideHookSetsTheTimeout() throws {
        let suite = "co.sstools.roadie.tests.overlayIdle.\(UUID())"
        let arguments = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { arguments.removePersistentDomain(forName: suite) }
        arguments.set("1", forKey: RoadieConfiguration.Argument.visOverlayIdle)
        let parsed = RoadieConfiguration.fromProcess(arguments: arguments, hostedTestRun: false)
        XCTAssertEqual(parsed.visOverlayIdle, 1)
        let vis = try openVis { $0.visOverlayIdle = parsed.visOverlayIdle }
        XCTAssertEqual(vis.overlay.idleTimeout, 1)
        vis.syncOverlayPlaybackHold(state: .playing)
        vis.showOverlay()
        now = 1.2
        vis.tickOverlay()
        XCTAssertFalse(vis.overlay.isOverlayVisible)
        vis.stopOverlayTimer()
    }
}

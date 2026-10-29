import AppKit
import AudioCore
import Foundation
import MusicBackendKit
import Observation
import VisualizationKit

/// One run of the song title animation (#0239, design §2.7): a new show (a new `id`) replaces a running one.
struct SongTitleShow: Equatable {
    var id: Int
    var text: String
}

/// The title, fps and help bookkeeping `VisualizationModel` keeps out of observation.
struct TitleState {
    /// The last track seen while the window is open; nil until the first one after opening.
    var trackIdentity: String?
    /// Bumped by each `open()`; a chain armed under an older generation stops re-arming (#0248).
    var trackGeneration = 0
    /// Track observations armed and not yet fired, for the tests (#0248): one after a change settles.
    var armedTrackObservations = 0
    var titleTimer: Timer?
    var fpsWindowStart: TimeInterval?
    var fpsFrames = 0
}

/// The song title on track change and on T, the F2–F5 readouts and the F1 / ? help card (#0239, design §1.5, §2.7).
extension VisualizationModel {
    /// The whole show: 0.5 s in, 2 s hold, 1 s out.
    static let songTitleDuration: TimeInterval = 3.5

    /// "Artist – Title", the title alone with no artist; nil with no title.
    static func songTitleText(title: String?, artist: String?) -> String? {
        guard let title, !title.isEmpty else { return nil }
        guard let artist, !artist.isEmpty else { return title }
        return "\(artist) – \(title)"
    }

    /// The current track's "Artist – Title" (the snapshot's, else the local queue's).
    var currentSongTitleText: String? {
        guard let owner else { return nil }
        let current = owner.playsLocalQueue ? owner.player.queue.current : nil
        return Self.songTitleText(
            title: owner.nowPlaying.title ?? current?.title, artist: owner.nowPlaying.artist ?? current?.artist)
    }

    /// What identifies the current track (`trackIdentity(nowPlaying:current:)`).
    var currentTrackIdentity: String? {
        guard let owner else { return nil }
        let current = owner.playsLocalQueue ? owner.player.queue.current : nil
        return Self.trackIdentity(nowPlaying: owner.nowPlaying, current: current)
    }

    /// The local queue entry, else the snapshot's item (a Music Assistant id), else the title alone (#0248): a
    /// metadata refresh of the same item, such as a late artist, keeps it.
    static func trackIdentity(nowPlaying: NowPlaying, current: Track?) -> String? {
        if let current { return "queue:\(current.id)" }
        if let item = nowPlaying.item { return "item:\(item)" }
        guard let title = nowPlaying.title, !title.isEmpty else { return nil }
        return "title:\(title)"
    }

    /// Reduce Motion (or its Debug stand-in, #0242): the title fades without growing.
    var reducesMotion: Bool { accessibilityState.reduceMotion }

    // MARK: Song title

    /// From `open()`: the track playing now is remembered without a show, then each change is observed.
    func startTrackingTitle() {
        titleState.trackIdentity = currentTrackIdentity
        // A chain from an earlier open that saw no change is still armed; the new generation ends it (#0248).
        titleState.trackGeneration += 1
        observeTrack()
    }

    private func observeTrack() {
        guard isOpen else { return }
        let generation = titleState.trackGeneration
        titleState.armedTrackObservations += 1
        let identity = withObservationTracking { currentTrackIdentity } onChange: { [weak self] in
            Task { @MainActor in self?.rearmTrackObservation(generation) }
        }
        noteTrack(identity: identity, text: currentSongTitleText)
    }

    private func rearmTrackObservation(_ generation: Int) {
        titleState.armedTrackObservations -= 1
        guard isOpen, generation == titleState.trackGeneration else { return }
        observeTrack()
    }

    /// A track identity seen while open: a change shows the title (when the setting is on); the first track after
    /// opening, and nothing playing, don't.
    func noteTrack(identity: String?, text: String?) {
        guard isOpen, let identity else { return }
        let previous = titleState.trackIdentity
        guard identity != previous else { return }
        titleState.trackIdentity = identity
        guard previous != nil, settings.songTitleOnTrackChange, let text else { return }
        showSongTitle(text)
    }

    /// T: the current track's title, or "Nothing is playing".
    func showSongTitleNow() {
        showSongTitle(currentSongTitleText ?? VisualizationOverlayContent.nothingPlaying)
    }

    func showSongTitle(_ text: String) {
        songTitleShowCount += 1
        let id = songTitleShowCount
        songTitle = SongTitleShow(id: id, text: text)
        announceForVoiceOver(text)
        titleState.titleTimer?.invalidate()
        let timer = Timer(timeInterval: Self.songTitleDuration, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.songTitle?.id == id else { return }
                self.songTitle = nil
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        titleState.titleTimer = timer
    }

    // MARK: Readouts

    /// F2–F5: on or off, saved.
    func toggleReadout(_ readout: VisReadout) {
        updateSettings { settings in
            if settings.readouts.contains(readout) {
                settings.readouts.remove(readout)
            } else {
                settings.readouts.insert(readout)
            }
        }
    }

    /// Whether `readout` shows now: on, and not one the overlay card or its strip already shows while it's up.
    func showsReadout(_ readout: VisReadout) -> Bool {
        Self.showsReadout(readout, on: settings.readouts, overlayVisible: overlay.isOverlayVisible)
    }

    static func showsReadout(_ readout: VisReadout, on readouts: Set<VisReadout>, overlayVisible: Bool) -> Bool {
        guard readouts.contains(readout) else { return false }
        return readout == .fps || !overlayVisible
    }

    /// "1:12 / 5:20", or the elapsed time alone with no duration; nil when nothing plays.
    static func timeReadout(_ content: VisualizationOverlayContent) -> String? {
        guard let elapsed = content.elapsed else { return nil }
        let clock = VisualizationOverlayContent.clock
        guard let duration = content.duration else { return clock(elapsed) }
        return "\(clock(elapsed)) / \(clock(duration))"
    }

    /// One drawn frame; once a second the rate is folded into `measuredFPS`.
    func countFrame(at now: TimeInterval) {
        guard let start = titleState.fpsWindowStart, now >= start else {
            titleState.fpsWindowStart = now
            titleState.fpsFrames = 0
            return
        }
        titleState.fpsFrames += 1
        let elapsed = now - start
        guard elapsed >= 1 else { return }
        let rate = Double(titleState.fpsFrames) / elapsed
        measuredFPS = measuredFPS == 0 ? rate : measuredFPS * 0.5 + rate * 0.5
        titleState.fpsWindowStart = now
        titleState.fpsFrames = 0
    }

    // MARK: Help

    /// `isHelpOpen` changed: the overlay holds and auto-advance waits while it's open.
    func helpOpenChanged() {
        setSuspended(.help, isHelpOpen)
        setOverlayHold(.help, isHelpOpen)
    }
}

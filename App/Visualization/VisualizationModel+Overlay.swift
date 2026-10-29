import AudioCore
import Foundation
import MusicBackendKit
import VisualizationKit

/// What the song overlay shows (#0238, design §2.4): worked out from the player's state, so tests build it directly.
struct VisualizationOverlayContent: Equatable {
    var title: String
    /// "Artist — Album", the album left out when unknown; nil with no artist either.
    var artistLine: String?
    var state: NowPlaying.State
    /// nil when nothing is playing.
    var elapsed: TimeInterval?
    var duration: TimeInterval?
    var showsRemaining: Bool
    /// "Next: <title>" from the local queue; nil when it doesn't know.
    var next: String?
    /// "<output> · Volume 72%".
    var outputLine: String
    /// Why the picture is idle while a speaker plays.
    var note: String?
    var showsNoAudioBadge: Bool

    static let nothingPlaying = "Nothing is playing"

    static func make(
        nowPlaying: NowPlaying, current: Track?, next: Track?, outputName: String, volume: Float,
        audioSource: VisualizationModel.AudioSource, elapsed: TimeInterval, showsRemaining: Bool
    ) -> VisualizationOverlayContent {
        let title = nowPlaying.title ?? current?.title
        let artist = nowPlaying.artist ?? current?.artist
        let album = nowPlaying.album ?? current?.album
        let idle = nowPlaying.state == .stopped && title == nil
        var artistLine: String?
        if let artist, !artist.isEmpty {
            artistLine = album.flatMap { $0.isEmpty ? nil : "\(artist) — \($0)" } ?? artist
        } else if let album, !album.isEmpty {
            artistLine = album
        }
        var note: String?
        if case .remote(let name) = audioSource {
            note = "Playing on \(name). The visualization needs the music playing on this Mac."
        }
        let duration = nowPlaying.duration ?? current?.duration
        return VisualizationOverlayContent(
            title: idle ? nothingPlaying : (title ?? "Untitled"),
            artistLine: idle ? nil : artistLine,
            state: nowPlaying.state,
            elapsed: idle ? nil : elapsed,
            duration: idle ? nil : duration.flatMap { $0 > 0 ? $0 : nil },
            showsRemaining: showsRemaining,
            next: idle ? nil : next.map { "Next: \($0.title)" },
            outputLine: "\(outputName) · Volume \(Int((volume * 100).rounded()))%",
            note: note,
            showsNoAudioBadge: note != nil)
    }

    var stateSymbol: String {
        switch state {
        case .playing: "▶"
        case .paused: "❚❚"
        case .stopped: "■"
        case .loading: "Loading…"
        }
    }

    var stateLabel: String {
        switch state {
        case .playing: "Playing"
        case .paused: "Paused"
        case .stopped: "Stopped"
        case .loading: "Loading"
        }
    }

    /// The trailing time: total, or "-remaining" when the main window shows remaining time.
    var trailingTime: String? {
        guard let duration else { return nil }
        if showsRemaining, let elapsed { return "-" + Self.clock(max(0, duration - elapsed)) }
        return Self.clock(duration)
    }

    /// "Elapsed 1:12 of 5:20".
    var timeLabel: String? {
        guard let elapsed else { return nil }
        guard let duration else { return "Elapsed \(Self.clock(elapsed))" }
        return "Elapsed \(Self.clock(elapsed)) of \(Self.clock(duration))"
    }

    var progress: Double? {
        guard let elapsed, let duration, duration > 0 else { return nil }
        return min(max(elapsed / duration, 0), 1)
    }

    static func clock(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded(.down))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        if hours > 0 { return String(format: "%d:%02d:%02d", hours, minutes, secs) }
        return String(format: "%d:%02d", minutes, secs)
    }
}

/// The song overlay's idle hiding (#0238, design §1.4): pointer input, holds and the one-shot timer. Keys don't feed it.
extension VisualizationModel {
    /// The key hint shows for the first three times the overlay comes up in a launch.
    var showsOverlayKeyHint: Bool { overlayShowCount <= 3 }

    /// The overlay's content now, `at` the time to work out a remote output's elapsed time.
    func overlayContent(at date: Date = Date()) -> VisualizationOverlayContent {
        guard let owner else {
            return .make(
                nowPlaying: .idle(on: OutputDevice.thisMacID), current: nil, next: nil, outputName: "This Mac",
                volume: 1, audioSource: .none, elapsed: 0, showsRemaining: false)
        }
        let status = owner.mainWindowStatus(at: date)
        let local = owner.playsLocalQueue
        let queue = owner.player.queue
        let next = local ? queue.indexAfterCurrentEnds().flatMap { queue.tracks.indices.contains($0) ? queue.tracks[$0] : nil }
            : nil
        let outputName = owner.selectedOutput == OutputDevice.thisMacID
            ? "This Mac" : owner.outputPicker.devices.first { $0.id == owner.selectedOutput }?.name ?? owner.selectedOutput.rawValue
        return .make(
            nowPlaying: owner.nowPlaying, current: local ? queue.current : nil, next: next, outputName: outputName,
            volume: owner.volume, audioSource: audioSource, elapsed: status.elapsed,
            showsRemaining: owner.timeMode == .remaining)
    }

    /// Window opened or entered full screen.
    func showOverlay() {
        let wasVisible = overlay.isOverlayVisible
        overlay.show(at: currentTime())
        syncPointerInside()
        overlayChanged(wasVisible: wasVisible, force: true)
    }

    /// The pointer isn't over the picture (opened by key from another window, or it left while the window wasn't
    /// key): the state machine stops counting it inside, so the cursor never hides there.
    func syncPointerInside() {
        if let isPointerInside, !isPointerInside() { overlay.pointerExited(at: currentTime()) }
    }

    /// Settings › Visualization's idle time changed (#0241): the running overlay takes it, shown and counting again
    /// from now; Never keeps it up.
    func applyOverlayIdleTimeout() {
        let wasVisible = overlay.isOverlayVisible
        overlay.idleTimeout = overlayIdleTimeout
        overlay.show(at: currentTime())
        syncPointerInside()
        overlayChanged(wasVisible: wasVisible)
    }

    func overlayPointerMoved(inside: Bool) {
        let wasVisible = overlay.isOverlayVisible
        overlay.pointerMoved(at: currentTime(), inside: inside)
        overlayChanged(wasVisible: wasVisible)
    }

    func overlayPointerExited() {
        overlay.pointerExited(at: currentTime())
        scheduleOverlayTick()
    }

    /// Holds the overlay up for `hold` (`.menu`, `.pointerOnOverlay`, `.notPlaying`; later `.browser`, `.help` …).
    /// The preset list (#0240) holds `.browser` while it's open.
    func setOverlayHold(_ hold: OverlayVisibility.Hold, _ on: Bool) {
        var holds = overlay.holds
        if on { holds.insert(hold) } else { holds.remove(hold) }
        guard holds != overlay.holds else { return }
        let wasVisible = overlay.isOverlayVisible
        overlay.setHolds(holds, at: currentTime())
        overlayChanged(wasVisible: wasVisible)
    }

    /// `.notPlaying` while the player isn't playing or loading; `state` defaults to the player's.
    func syncOverlayPlaybackHold(state: NowPlaying.State? = nil) {
        let state = state ?? owner?.playbackState ?? .stopped
        setOverlayHold(.notPlaying, !(state == .playing || state == .loading))
    }

    /// The idle timer's fire: hides the overlay (and the cursor, when the pointer is inside) once the deadline passed.
    func tickOverlay() {
        syncPointerInside()
        overlay.tick(at: currentTime())
        if overlay.isCursorHidden { hideCursor?() }
        scheduleOverlayTick()
    }

    /// Stops the timer (the window closed).
    func stopOverlayTimer() {
        overlayTimer?.invalidate()
        overlayTimer = nil
    }

    private func overlayChanged(wasVisible: Bool, force: Bool = false) {
        if overlay.isOverlayVisible, !wasVisible || force && overlayShowCount == 0 { overlayShowCount += 1 }
        scheduleOverlayTick()
    }

    /// One one-shot timer for `overlay.nextDeadline`, rescheduled after every input; none once hidden or held.
    private func scheduleOverlayTick() {
        overlayTimer?.invalidate()
        overlayTimer = nil
        guard overlay.isOverlayVisible, let deadline = overlay.nextDeadline else { return }
        let delay = max(0.01, deadline - currentTime())
        let timer = Timer(timeInterval: delay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.tickOverlay() }
        }
        RunLoop.main.add(timer, forMode: .common)
        overlayTimer = timer
    }
}

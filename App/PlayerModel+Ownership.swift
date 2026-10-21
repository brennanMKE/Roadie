import AudioCore
import Foundation
import LibraryBrowser
import MusicAssistantKit
import MusicBackendKit
import os

/// #0121: SkinAmp follows what Music Assistant plays, only one place plays, and quitting stops the target.
/// The decisions are `PlaybackOwnership` and `QuitStop`; this only wires them in.
extension PlayerModel {
    private static let ownershipLog = Logger(subsystem: "com.brennanmke.SkinAmp", category: "PlaybackOwnership")

    /// What the target plays now: AudioCore's state for This Mac on the local feed, else its now-playing state.
    var targetState: NowPlaying.State {
        guard playsLocalQueue else { return nowPlaying.state }
        switch player.state {
        case .stopped: return .stopped
        case .loading: return .loading
        case .playing: return .playing
        case .paused: return .paused
        }
    }

    func watchPlaybackActivity() {
        let ma = musicAssistant
        activityTask = Task { [weak self] in
            for await snapshot in await ma.playbackActivity() {
                guard let self else { return }
                self.activityChanged(snapshot)
            }
        }
    }

    private func activityChanged(_ snapshot: [OutputActivity]) {
        let previous = activity
        activity = snapshot
        guard !snapshot.isEmpty else {
            activityAfterConnect = true
            return
        }
        let trigger: PlaybackOwnership.Trigger =
            activityAfterConnect || previous.isEmpty ? .connected : .activityChanged(previous: previous)
        activityAfterConnect = false
        if let id = PlaybackOwnership.adoption(
            selected: selectedOutput, selectedState: targetState, activity: snapshot, trigger: trigger)
        {
            adopt(id)
        }
    }

    /// Makes `id` the target without moving anything (never `selectOutput`), and says so in the marquee.
    func adopt(_ id: OutputDevice.ID) {
        guard id != selectedOutput else { return }
        let name = id == OutputDevice.thisMacID
            ? OutputDevice.thisMac.name : (activity.first { $0.output == id }?.name ?? id.rawValue)
        Self.ownershipLog.info("adopting the playing Music Assistant output")
        selectedOutput = id
        post(StatusNotice(text: "Output: " + Self.truncated(name, to: 31 - "Output: ".utf16.count)))
        if id != OutputDevice.thisMacID, player.state == .playing || sendspinController.sendspin.isStreaming {
            stopOthers(startingOn: id)
        }
    }

    /// Stops SkinAmp's other place when it starts playback on `target` (`PlaybackOwnership.stops`). nil when nothing
    /// needs stopping; otherwise the task sending the stops, which a play can await first.
    @discardableResult
    func stopOthers(startingOn target: OutputDevice.ID) -> Task<Void, Never>? {
        let sounding = player.state == .playing || sendspinController.sendspin.isStreaming
        let stops = PlaybackOwnership.stops(
            startingOn: target, previous: previousTarget, thisMacFeed: thisMacFeed, thisMacSounding: sounding,
            activity: activity)
        guard !stops.isEmpty else { return nil }
        let local = router.local
        let ma = musicAssistant
        return Task {
            for stop in stops {
                switch stop {
                case .thisMacLocal: try? await local.transport(.stop, on: OutputDevice.thisMacID)
                case .musicAssistant(let id): try? await ma.transport(.stop, on: id)
                }
            }
        }
    }

    /// Music Assistant started streaming to This Mac. A stream SkinAmp didn't ask for while a speaker is the target
    /// makes This Mac the target and stops the speaker, so the two never play at once.
    func streamStarted() {
        applyFeed(.streamStarted)
        let requested = ownStreamRequested
        ownStreamRequested = false
        guard !requested, selectedOutput != OutputDevice.thisMacID else { return }
        adopt(OutputDevice.thisMacID)
        stopOthers(startingOn: OutputDevice.thisMacID)
    }

    /// The stop sent on quit: the target speaker and This Mac's Music Assistant player, capped at
    /// `QuitStop.timeout`. nil when there is nothing to stop (turned off, not connected, local playback).
    func stopPlaybackForQuit() -> Task<Void, Never>? {
        let enabled = UserDefaults.standard.object(forKey: QuitStop.defaultsKey) as? Bool ?? true
        let targets = QuitStop.targets(
            enabled: enabled, isConnected: musicAssistantIsConnected, selected: selectedOutput,
            thisMacFeed: thisMacFeed)
        guard !targets.isEmpty else { return nil }
        let ma = musicAssistant
        return Task {
            if await QuitStop.run(targets, on: ma) == .timedOut {
                Self.ownershipLog.info("quit stop timed out")
            }
        }
    }
}

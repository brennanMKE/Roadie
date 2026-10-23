import Foundation
import MusicBackendKit
import os

/// Which output Roadie's transport follows, and what it stops so only one place plays (#0121). Pure: the app wires
/// these into `PlayerModel`.
public enum PlaybackOwnership {
    public enum Trigger: Sendable { case connected, activityChanged(previous: [OutputActivity]) }

    /// The output to adopt, or nil to keep `selected`. `selectedState` is what the target plays now (AudioCore's
    /// state for This Mac on the local feed, else its `nowPlaying.state`).
    public static func adoption(
        selected: OutputDevice.ID, selectedState: NowPlaying.State, activity: [OutputActivity], trigger: Trigger
    ) -> OutputDevice.ID? {
        if selectedState == .playing || selectedState == .loading { return nil }
        let leaders = activity.filter { $0.leader == nil && $0.output != selected }
        let newest: ([OutputActivity]) -> OutputDevice.ID? = { candidates in
            candidates.max { ($0.updatedAt ?? 0) < ($1.updatedAt ?? 0) }?.output
        }
        switch trigger {
        case .connected:
            if let id = newest(leaders.filter { $0.state == .playing }) { return id }
            guard selectedState == .stopped else { return nil }
            return newest(leaders.filter { $0.state == .paused })
        case .activityChanged(let previous):
            let wasPlaying = Set(previous.filter { $0.state == .playing }.map(\.output))
            return newest(leaders.filter { $0.state == .playing && !wasPlaying.contains($0.output) })
        }
    }

    public enum Stop: Hashable, Sendable { case thisMacLocal, musicAssistant(OutputDevice.ID) }

    /// What to stop when Roadie starts playback on `target`. `thisMacSounding`: AudioCore plays, or a Sendspin
    /// stream runs. Players other than This Mac and the previous target are never touched.
    public static func stops(
        startingOn target: OutputDevice.ID, previous: OutputDevice.ID?, thisMacFeed: ThisMacFeed,
        thisMacSounding: Bool, activity: [OutputActivity]
    ) -> [Stop] {
        var result: [Stop] = []
        // This Mac synced to `target` (#0118) plays with it; stopping it would reach the leader through the redirect.
        let thisMacFollowsTarget = activity.first { $0.output == OutputDevice.thisMacID }?.leader == target
        if target != OutputDevice.thisMacID, thisMacSounding, !thisMacFollowsTarget {
            result.append(thisMacFeed == .musicAssistant ? .musicAssistant(OutputDevice.thisMacID) : .thisMacLocal)
        }
        if let previous, previous != target, previous != OutputDevice.thisMacID,
            let old = activity.first(where: { $0.output == previous }), old.state == .playing || old.state == .paused,
            old.leader != target, activity.first(where: { $0.output == target })?.leader != previous
        {
            result.append(.musicAssistant(previous))
        }
        return result
    }
}

/// Stopping Music Assistant playback when Roadie quits (#0121).
public enum QuitStop {
    public static let defaultsKey = "musicAssistant.stopOnQuit"
    public static let timeout: Duration = .milliseconds(1500)

    /// The Music Assistant outputs to stop on quit; empty when turned off or not connected. `members` are the
    /// speakers synced to `selected` (#0118); they are stopped too.
    public static func targets(
        enabled: Bool, isConnected: Bool, selected: OutputDevice.ID, members: [OutputDevice.ID] = [],
        thisMacFeed: ThisMacFeed
    ) -> [OutputDevice.ID] {
        guard enabled, isConnected else { return [] }
        var ids: [OutputDevice.ID] = []
        for id in [selected] + members where id != OutputDevice.thisMacID && !ids.contains(id) { ids.append(id) }
        if thisMacFeed == .musicAssistant { ids.append(OutputDevice.thisMacID) }
        return ids
    }

    public enum Outcome: Equatable, Sendable { case sent, timedOut }

    /// Sends `.stop` to each target at once; returns when all are answered or `timeout` passes, whichever is first.
    public static func run(
        _ targets: [OutputDevice.ID], on backend: any MusicBackend, timeout: Duration = timeout,
        clock: any Clock<Duration> = ContinuousClock()
    ) async -> Outcome {
        guard !targets.isEmpty else { return .sent }
        // Unstructured on purpose: a request that ignores cancellation must not hold quitting past the timeout.
        return await withCheckedContinuation { (continuation: CheckedContinuation<Outcome, Never>) in
            let resumed = OSAllocatedUnfairLock(initialState: false)
            let finish: @Sendable (Outcome) -> Void = { outcome in
                let first = resumed.withLock { done -> Bool in
                    defer { done = true }
                    return !done
                }
                if first { continuation.resume(returning: outcome) }
            }
            let timer = Task {
                do { try await clock.sleep(for: timeout) } catch { return }
                finish(.timedOut)
            }
            Task {
                await withTaskGroup(of: Void.self) { group in
                    for id in targets { group.addTask { try? await backend.transport(.stop, on: id) } }
                }
                timer.cancel()
                finish(.sent)
            }
        }
    }
}

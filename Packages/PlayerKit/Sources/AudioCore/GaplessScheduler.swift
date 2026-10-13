import Foundation

/// Identifies one schedule call. Completion handlers capture it; `GaplessScheduler.complete`
/// rejects tokens from before the last `invalidate()`.
struct ScheduleToken: Hashable, Sendable {
    let generation: UInt64
    let sequence: UInt64
}

/// One file (or segment of a file) queued on the player node.
struct ScheduledItem: Equatable, Sendable {
    let token: ScheduleToken
    let trackID: UUID
    /// Start on the node's sample timeline (node-rate frames).
    let startFrame: Int64
    /// Length in node-rate frames (see `nodeFrames`).
    let frameLength: Int64
    /// Seconds into the file where the segment starts (non-zero after a seek).
    let seekOffset: TimeInterval
}

enum SchedulingDecision: Equatable, Sendable {
    /// Nothing to change.
    case keep
    /// Nothing is pre-scheduled but the queue has a next track.
    case scheduleNext
    /// The pre-scheduled file is no longer the next track; the node cannot drop only
    /// the second item, so restart the current track and look ahead again.
    case restartCurrent

    static func reconcile(queueNext: UUID?, scheduledNext: UUID?) -> SchedulingDecision {
        switch (queueNext, scheduledNext) {
        case (nil, nil): .keep
        case (.some, nil): .scheduleNext
        case (_, .some(let scheduled)): scheduled == queueNext ? .keep : .restartCurrent
        }
    }
}

/// Pure bookkeeping for the player node's schedule: no AVFoundation.
struct GaplessScheduler: Sendable {
    enum CompletionOutcome: Equatable, Sendable {
        case stale
        case advanced(to: UUID)
        case reachedEnd
    }

    private(set) var generation: UInt64 = 0
    private var sequence: UInt64 = 0
    /// `items[0]` is the one audibly playing; at most one more is queued behind it.
    private(set) var items: [ScheduledItem] = []

    var currentTrackID: UUID? { items.first?.trackID }
    var scheduledNextTrackID: UUID? { items.count > 1 ? items[1].trackID : nil }

    /// Call before every `playerNode.stop()`: the node fires the completion handler of
    /// every item it discards, and those must all be stale.
    mutating func invalidate() {
        generation += 1
        items.removeAll()
    }

    mutating func append(trackID: UUID, frameLength: Int64, seekOffset: TimeInterval = 0) -> ScheduledItem {
        sequence += 1
        let item = ScheduledItem(
            token: ScheduleToken(generation: generation, sequence: sequence),
            trackID: trackID,
            startFrame: items.last.map { $0.startFrame + $0.frameLength } ?? 0,
            frameLength: frameLength,
            seekOffset: seekOffset
        )
        items.append(item)
        return item
    }

    mutating func complete(_ token: ScheduleToken) -> CompletionOutcome {
        guard token.generation == generation, items.first?.token == token else { return .stale }
        items.removeFirst()
        if let next = items.first { return .advanced(to: next.trackID) }
        return .reachedEnd
    }

    /// Seconds into the audible item's file for a node sample time. Clamped to the item,
    /// so it stays right between the real boundary and the completion callback arriving.
    func position(atNodeSampleTime sample: Int64, nodeSampleRate: Double) -> TimeInterval? {
        guard let head = items.first, nodeSampleRate > 0 else { return nil }
        let played = min(max(sample - head.startFrame, 0), head.frameLength)
        return head.seekOffset + Double(played) / nodeSampleRate
    }

    /// File frames expressed on the node's timeline.
    static func nodeFrames(fileFrames: Int64, fileSampleRate: Double, nodeSampleRate: Double) -> Int64 {
        guard fileSampleRate > 0, nodeSampleRate > 0, fileSampleRate != nodeSampleRate else { return fileFrames }
        return Int64((Double(fileFrames) * nodeSampleRate / fileSampleRate).rounded())
    }
}

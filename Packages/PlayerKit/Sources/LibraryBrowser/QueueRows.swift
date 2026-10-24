import Foundation
import MusicBackendKit

/// Where the playlist editor's rows come from (#0144, design §2.6).
public enum QueueRowsSource: Hashable, Sendable {
    /// AudioCore's queue.
    case local
    /// The queue the backend plays on this output (a speaker's leader, or the player wrapping This Mac).
    case remote(OutputDevice.ID)
    /// Nothing to show: a speaker of a backend that can't list its queue.
    case none
}

public enum QueueRowsSelection {
    /// This Mac on its local queue → local; This Mac fed by Music Assistant → the wrapper's remote queue; a speaker →
    /// its remote queue when the backend that owns it can show one, else nothing.
    public static func choose(
        output: OutputDevice.ID, feed: ThisMacFeed, remoteCapabilities: BackendCapabilities
    ) -> QueueRowsSource {
        if output == OutputDevice.thisMacID, feed == .local { return .local }
        return remoteCapabilities.contains(.queueEditing) ? .remote(output) : .none
    }
}

/// Text and arithmetic for a remote queue's rows; the window formats times and numbers itself.
public enum QueueRows {
    /// "artist - title", else the title.
    public static func rowText(_ item: RemoteQueueItem) -> String {
        if let artist = item.artist, !artist.isEmpty, !item.title.isEmpty { return "\(artist) - \(item.title)" }
        return item.title
    }

    /// Seconds of the selected rows and of all rows; unknown durations count as 0.
    public static func runningTime(_ items: [RemoteQueueItem], selected: Set<String>) -> (selected: TimeInterval, total: TimeInterval) {
        var total: TimeInterval = 0, picked: TimeInterval = 0
        for item in items {
            let seconds = max(item.duration ?? 0, 0)
            total += seconds
            if selected.contains(item.id) { picked += seconds }
        }
        return (picked, total)
    }

    /// The rows Crop removes: every index not selected. Nothing when nothing is selected (Crop does nothing then).
    public static func indicesToRemove(cropping selected: Set<Int>, count: Int) -> [Int] {
        guard !selected.isEmpty else { return [] }
        return (0..<count).filter { !selected.contains($0) }
    }
}

/// Which edits a selection in the playlist editor becomes on a remote queue (#0145, design §2.6). Indices are rows of
/// the snapshot (0-based). The current row is never removed: Music Assistant's own UI won't either.
public enum QueueEditPlan {
    public struct Removal: Hashable, Sendable {
        /// Highest index first, the order the deletes are sent in.
        public var items: [RemoteQueueItem]
        /// Whether the current row was asked for and left out.
        public var skippedCurrent: Bool
    }

    public enum Move: Hashable, Sendable {
        case none
        /// More than one row selected: Music Assistant moves one item per call.
        case refusedMultiple
        case move(itemID: String, shift: Int)
    }

    /// The selected rows to delete.
    public static func remove(selected: Set<Int>, in snapshot: RemoteQueueSnapshot) -> Removal {
        removal(of: selected, in: snapshot)
    }

    /// Crop: every unselected row. Nothing when nothing is selected. An unselected current row simply stays, without
    /// the notice (it wasn't asked for).
    public static func crop(selected: Set<Int>, in snapshot: RemoteQueueSnapshot) -> Removal {
        var removal = removal(of: Set(QueueRows.indicesToRemove(cropping: selected, count: snapshot.items.count)), in: snapshot)
        removal.skippedCurrent = false
        return removal
    }

    /// A drag of the selection by `offset` rows, clamped to the queue.
    public static func move(selected: Set<Int>, by offset: Int, in snapshot: RemoteQueueSnapshot) -> Move {
        guard offset != 0, !selected.isEmpty else { return .none }
        guard selected.count == 1, let from = selected.first, snapshot.items.indices.contains(from) else {
            return selected.count > 1 ? .refusedMultiple : .none
        }
        let to = min(max(from + offset, 0), snapshot.items.count - 1)
        return to == from ? .none : .move(itemID: snapshot.items[from].id, shift: to - from)
    }

    /// The snapshot as it will look once `edit` lands, for the optimistic rows; the watcher's refetch confirms it.
    public static func apply(_ edit: QueueEdit, to snapshot: RemoteQueueSnapshot) -> RemoteQueueSnapshot {
        var result = snapshot
        var items = snapshot.items
        let currentID = snapshot.currentIndex.flatMap { items.indices.contains($0) ? items[$0].id : nil }
        switch edit {
        case .play:
            return snapshot
        case .remove(let removed):
            let ids = Set(removed.map(\.id))
            items.removeAll { ids.contains($0.id) }
        case .move(let itemID, let shift):
            guard let from = items.firstIndex(where: { $0.id == itemID }) else { return snapshot }
            let to = min(max(from + shift, 0), items.count - 1)
            items.insert(items.remove(at: from), at: to)
        case .clear:
            items = []
        }
        for i in items.indices { items[i].index = i }
        result.total = max(snapshot.total - (snapshot.items.count - items.count), items.count)
        result.items = items
        result.currentIndex = currentID.flatMap { id in items.firstIndex { $0.id == id } }
        return result
    }

    private static func removal(of rows: Set<Int>, in snapshot: RemoteQueueSnapshot) -> Removal {
        let current = snapshot.currentIndex
        let picked = rows.filter { snapshot.items.indices.contains($0) }
        let items = picked.filter { $0 != current }.sorted(by: >).map { snapshot.items[$0] }
        return Removal(items: items, skippedCurrent: current.map(picked.contains) ?? false)
    }
}

/// Queue (Q) on a remote queue (#0182): moves rows to play right after the current item, each after the ones queued
/// before it since the current item last changed. Music Assistant has no separate play-next list.
public struct RemoteUpNext: Hashable, Sendable {
    /// The current item's queue id when counting began.
    public private(set) var anchorItemID: String?
    /// How many rows were queued after the anchor.
    public private(set) var count = 0

    public init() {}

    /// Resets the count when the snapshot's current item is no longer the anchor.
    public mutating func sync(to snapshot: RemoteQueueSnapshot) {
        let current = snapshot.currentIndex.flatMap { snapshot.items.indices.contains($0) ? snapshot.items[$0].id : nil }
        guard current != anchorItemID else { return }
        anchorItemID = current
        count = 0
    }

    /// One Queue action's moves, sent in order; the first refusal stops the rest (#0182).
    public struct Batch: Hashable, Sendable {
        public var edits: [QueueEdit] = []
        /// For each edit, the snapshot just before it, with no later edits applied: what a refusal of that edit
        /// restores.
        public var before: [RemoteQueueSnapshot] = []
        /// For each edit, how many counted rows it and the rows after it in the batch account for: what a refusal
        /// of that edit takes back out of `count`.
        public var counted: [Int] = []
        /// The snapshot with every edit applied, shown at once.
        public var after: RemoteQueueSnapshot?
        /// The current item's id the batch counted after.
        public var anchorItemID: String?
    }

    /// The moves that put `rows` (snapshot indices, in the order chosen) after the current item and the rows
    /// queued before them. Skips the current row and rows that are already in place (they still count). Empty with
    /// no current item.
    public mutating func plan(queueing rows: [Int], in snapshot: RemoteQueueSnapshot) -> [QueueEdit] {
        batch(queueing: rows, in: snapshot).edits
    }

    /// `plan(queueing:in:)` with what's needed to undo a refusal part way through.
    public mutating func batch(queueing rows: [Int], in snapshot: RemoteQueueSnapshot) -> Batch {
        sync(to: snapshot)
        var batch = Batch(after: snapshot, anchorItemID: anchorItemID)
        guard let currentID = anchorItemID else { return batch }
        var working = snapshot
        // Rows this batch counted before each edit's row; the rest of the batch, from that row on, is the total less this.
        var countedBefore: [Int] = []
        let startCount = count
        for row in rows where snapshot.items.indices.contains(row) {
            let itemID = snapshot.items[row].id
            guard itemID != currentID,
                let from = working.items.firstIndex(where: { $0.id == itemID }),
                let c = working.currentIndex
            else { continue }
            // Removing a row above the current one shifts the current one up.
            let to = min((from < c ? c : c + 1) + count, working.items.count - 1)
            if to != from {
                let edit = QueueEdit.move(itemID: itemID, shift: to - from)
                batch.edits.append(edit)
                batch.before.append(working)
                countedBefore.append(count - startCount)
                working = QueueEditPlan.apply(edit, to: working)
            }
            count += 1
        }
        let added = count - startCount
        batch.counted = countedBefore.map { added - $0 }
        batch.after = working
        return batch
    }

    /// Takes `n` refused rows back out of the count, only while `anchor` is still the current item, never below 0.
    public mutating func uncount(_ n: Int, anchor: String?) {
        guard anchor != nil, anchor == anchorItemID else { return }
        count = max(0, count - n)
    }
}

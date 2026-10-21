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

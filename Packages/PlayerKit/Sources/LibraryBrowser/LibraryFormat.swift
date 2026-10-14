import Foundation
import MusicBackendKit

/// Pure text formatting for the browser's rows and headers.
public enum LibraryFormat {
    /// "3:06", "1:02:03" above an hour, "–:––" when unknown.
    public static func duration(_ seconds: TimeInterval?) -> String {
        guard let seconds, seconds.isFinite else { return "\u{2013}:\u{2013}\u{2013}" }
        let total = Int(max(0, seconds))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        if hours > 0 { return String(format: "%d:%02d:%02d", hours, minutes, secs) }
        return String(format: "%d:%02d", minutes, secs)
    }

    /// "9", or "2-3" when the disc number is above 1; empty without a track number.
    public static func trackNumber(_ track: LibraryTrack) -> String {
        guard let number = track.trackNumber else { return "" }
        if let disc = track.discNumber, disc > 1 { return "\(disc)-\(number)" }
        return "\(number)"
    }

    /// "23 of 242" when the total is known, else nil.
    public static func countLabel(loaded: Int, total: Int?) -> String? {
        guard let total else { return nil }
        return "\(loaded) of \(total)"
    }

    @MainActor
    public static func countLabel<Item>(_ list: PagedList<Item>) -> String? {
        countLabel(loaded: list.items.count, total: list.total)
    }
}

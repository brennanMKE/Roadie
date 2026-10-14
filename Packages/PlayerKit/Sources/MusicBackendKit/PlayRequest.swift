import Foundation

/// What the browser asks a backend to play: the result of a double-click, Play or Add to Playlist.
/// Pure, so the rules are tested without a view and are the same for every backend.
public struct PlayRequest: Hashable, Sendable {
    public var items: [MediaID]
    public var mode: PlayMode

    public init(items: [MediaID], mode: PlayMode) {
        self.items = items
        self.mode = mode
    }

    /// An album row: the album in order, replacing the queue. The backend expands the id.
    public static func play(album: MediaID) -> PlayRequest {
        PlayRequest(items: [album], mode: .replace())
    }

    /// An album row: the album appended to the queue.
    public static func append(album: MediaID) -> PlayRequest {
        PlayRequest(items: [album], mode: .append)
    }

    /// Track rows, `rows` in display order. One selected row inside `album` plays every row from
    /// that one (`.replace(startIndex:)`); several rows, or a row with no album (search), play just
    /// the selected rows in display order. nil when nothing selected is in `rows`.
    public static func play(_ selected: Set<MediaID>, in rows: [LibraryTrack], album: MediaID?) -> PlayRequest? {
        let picked = rows.filter { selected.contains($0.id) }
        guard let first = picked.first else { return nil }
        if picked.count == 1, album != nil, let index = rows.firstIndex(where: { $0.id == first.id }) {
            return PlayRequest(items: rows.map(\.id), mode: .replace(startIndex: index))
        }
        return PlayRequest(items: picked.map(\.id), mode: .replace())
    }

    /// The selected rows in display order, appended. nil when none is in `rows`.
    public static func append(_ selected: Set<MediaID>, in rows: [LibraryTrack]) -> PlayRequest? {
        let picked = rows.filter { selected.contains($0.id) }
        guard !picked.isEmpty else { return nil }
        return PlayRequest(items: picked.map(\.id), mode: .append)
    }
}

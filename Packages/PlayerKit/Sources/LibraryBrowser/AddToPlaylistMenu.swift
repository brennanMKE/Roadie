import Foundation
import MusicBackendKit

/// The "Add to Playlist ▸" submenu's entries (#0136): playlists whose tracks can be edited, the most recently used
/// first (up to `recentLimit`), then the rest by name, then "New Playlist…". The playlist being viewed is left out.
public enum AddToPlaylistMenu {
    public enum Entry: Hashable, Identifiable, Sendable {
        case playlist(LibraryPlaylist)
        case separator
        case newPlaylist

        public var id: String {
            switch self {
            case .playlist(let playlist): "playlist:" + playlist.id.rawValue
            case .separator: "separator"
            case .newPlaylist: "new"
            }
        }
    }

    public static let recentLimit = 3

    public static func entries(
        playlists: [LibraryPlaylist], recent: [MediaID], excluding open: MediaID? = nil
    ) -> [Entry] {
        let targets = playlists.filter { $0.editing.contains(.addRemove) && $0.id != open }
        var seen = Set<MediaID>()
        var ordered: [LibraryPlaylist] = []
        for id in recent where ordered.count < recentLimit {
            if let playlist = targets.first(where: { $0.id == id }), seen.insert(id).inserted { ordered.append(playlist) }
        }
        let rest = targets.filter { !seen.contains($0.id) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        var seenRest = Set<MediaID>()
        ordered += rest.filter { seenRest.insert($0.id).inserted }
        let rows = ordered.map(Entry.playlist)
        return rows.isEmpty ? [.newPlaylist] : rows + [.separator, .newPlaylist]
    }

    /// `recent` with `id` moved to the front, at most `recentLimit` long.
    public static func recording(_ id: MediaID, in recent: [MediaID]) -> [MediaID] {
        Array(([id] + recent.filter { $0 != id }).prefix(recentLimit))
    }

    /// "Added 3 tracks to Road Trip", "Added 1 album to Road Trip".
    public static func notice(adding items: [MediaID], to playlist: LibraryPlaylist) -> String {
        let albums = items.filter { $0.kind == .album }.count
        let tracks = items.filter { $0.kind == .track }.count
        var parts: [String] = []
        if albums > 0 { parts.append(albums == 1 ? "1 album" : "\(albums) albums") }
        if tracks > 0 { parts.append(tracks == 1 ? "1 track" : "\(tracks) tracks") }
        let what = parts.isEmpty ? "nothing" : parts.joined(separator: " and ")
        return "Added \(what) to \(playlist.name)"
    }
}

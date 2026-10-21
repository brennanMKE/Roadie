import Foundation
import MusicBackendKit

/// The Playlists list's sections: "My Playlists", "Built-in", then one per provider in first-seen order. Within a
/// group the backend's order (MA's `sort_name`) is kept. Computed over the loaded items, so groups grow as pages land.
public enum PlaylistGrouping {
    public enum Kind: Hashable, Sendable {
        case mine
        case builtIn
        case provider(String)
    }

    public struct Group: Identifiable, Hashable, Sendable {
        public var kind: Kind
        public var playlists: [LibraryPlaylist]
        public var id: Kind { kind }

        /// "My Playlists", "Built-in", "Spotify", or "Spotify · read-only" when none of its playlists is editable.
        public var title: String {
            switch kind {
            case .mine: "My Playlists"
            case .builtIn: "Built-in"
            case .provider(let name): playlists.contains(where: \.isEditable) ? name : "\(name) · read-only"
            }
        }

        /// A provider group whose playlists are all read-only.
        public var isReadOnly: Bool {
            if case .provider = kind { return !playlists.contains(where: \.isEditable) }
            return false
        }
    }

    /// One row of the flattened list: a section header or a playlist.
    public enum Row: Identifiable, Hashable, Sendable {
        case header(Group)
        case playlist(LibraryPlaylist)

        public var id: String {
            switch self {
            case .header(let group): "header:\(group.kind)"
            case .playlist(let playlist): playlist.id.description
            }
        }
    }

    public static func kind(of playlist: LibraryPlaylist) -> Kind {
        switch playlist.source {
        case .builtIn: .builtIn
        case .provider(let name): .provider(name)
        // A read-only user playlist (no provider) still reads as the user's.
        case .user: .mine
        }
    }

    public static func groups(_ playlists: [LibraryPlaylist]) -> [Group] {
        var mine: [LibraryPlaylist] = []
        var builtIn: [LibraryPlaylist] = []
        var providers: [String] = []
        var byProvider: [String: [LibraryPlaylist]] = [:]
        for playlist in playlists {
            switch kind(of: playlist) {
            case .mine: mine.append(playlist)
            case .builtIn: builtIn.append(playlist)
            case .provider(let name):
                if byProvider[name] == nil { providers.append(name) }
                byProvider[name, default: []].append(playlist)
            }
        }
        var result: [Group] = []
        if !mine.isEmpty { result.append(Group(kind: .mine, playlists: mine)) }
        if !builtIn.isEmpty { result.append(Group(kind: .builtIn, playlists: builtIn)) }
        for name in providers { result.append(Group(kind: .provider(name), playlists: byProvider[name] ?? [])) }
        return result
    }

    public static func rows(_ playlists: [LibraryPlaylist]) -> [Row] {
        groups(playlists).flatMap { [Row.header($0)] + $0.playlists.map(Row.playlist) }
    }

    /// The trailing count: "∞" for a dynamic playlist, the track count when known.
    public static func countText(_ playlist: LibraryPlaylist) -> String? {
        if playlist.isDynamic { return "∞" }
        return playlist.trackCount.map(String.init)
    }

    /// The detail header's line after the track summary: source, owner, "Read-only", "Dynamic".
    public static func detailLine(_ playlist: LibraryPlaylist) -> String {
        var parts: [String] = []
        switch playlist.source {
        case .user: parts.append("Music Assistant")
        case .builtIn: parts.append("Built-in")
        case .provider(let name): parts.append(name)
        }
        if let owner = playlist.owner, !owner.isEmpty, owner != "Music Assistant" { parts.append(owner) }
        if !playlist.isEditable { parts.append("Read-only") }
        if playlist.isDynamic { parts.append("Dynamic") }
        return parts.joined(separator: " · ")
    }
}

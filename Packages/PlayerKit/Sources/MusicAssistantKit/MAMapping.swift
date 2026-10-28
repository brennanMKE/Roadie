import Foundation
import MusicBackendKit

/// Pure mappings from Music Assistant items to the source-neutral library models.
/// Identifiers are the item's `library://` URI; artwork references are image `proxy_id`s.
enum MAMapping {
    /// The first thumb with a proxy id, else the first image with one.
    static func artwork(_ metadata: MAMetadata?) -> ArtworkRef? {
        guard let images = metadata?.images else { return nil }
        let proxied = images.filter { ($0.proxyID ?? "").isEmpty == false }
        let pick = proxied.first { $0.type == "thumb" } ?? proxied.first
        return pick?.proxyID.map { ArtworkRef($0) }
    }

    static func artistNames(_ artists: [MAItemMapping]?) -> String? {
        guard let artists, !artists.isEmpty else { return nil }
        return artists.map { ArtistName.display($0.name) }.joined(separator: ", ")
    }

    /// The provider that owns a playlist's first mapping, else the item's own provider.
    static func playlistDomain(_ playlist: MAPlaylist) -> String? {
        playlist.providerMappings?.first?.providerDomain ?? playlist.provider
    }

    /// The builtin provider's generated playlist ids (`providers/builtin/constants.py`, docs/design/playlists.md §1.2).
    static let builtinPlaylistIDs: Set<String> = [
        "all_favorite_tracks", "random_artist", "random_album", "random_tracks", "recently_played",
        "recently_added_tracks", "infinite_mix", "infinite_mix_favorites",
    ]

    /// On the builtin provider, a playlist is `.builtIn` when its mapping's `item_id` is one of the generated ids or it
    /// is read-only; an editable one is the user's M3U-backed playlist. The owner can't tell them apart: the live server
    /// stamps "Music Assistant" on every builtin playlist, the user's own included (#0221); the recorder scrubbed owners
    /// to "user" before #0221. Anything else belongs to its provider.
    static func playlistSource(_ playlist: MAPlaylist) -> PlaylistSource {
        let domain = playlistDomain(playlist)
        switch domain {
        case "builtin":
            if let id = playlist.providerMappings?.first?.itemID, builtinPlaylistIDs.contains(id) { return .builtIn }
            return playlist.isEditable == true ? .user : .builtIn
        case nil, "library":
            return .user
        case let domain?:
            return .provider(name: providerDisplayName(domain))
        }
    }

    /// `spotify` → "Spotify", `apple_music` → "Apple Music". A display name from `providers` could replace this later.
    static func providerDisplayName(_ domain: String) -> String {
        let known = ["ytmusic": "YouTube Music", "tidal": "Tidal", "qobuz": "Qobuz", "plex": "Plex", "deezer": "Deezer",
                     "soundcloud": "SoundCloud", "filesystem_local": "Local Files", "filesystem_smb": "SMB Share"]
        if let name = known[domain] { return name }
        return domain.split(separator: "_").map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
    }
}

extension LibraryArtist {
    init(ma artist: MAArtist) {
        self.init(
            id: MediaID(.artist, artist.uri), name: ArtistName.display(artist.name), sortName: artist.sortName,
            artwork: MAMapping.artwork(artist.metadata))
        isFavorite = artist.favorite
    }
}

extension LibraryAlbum {
    /// MA stores some albums with an empty name (the folder name is only in the provider mapping); the fallback
    /// to that name, then "Untitled", is Roadie's choice. MA's own UI shows a blank.
    init(ma album: MAAlbum) {
        let title: String
        if !album.name.isEmpty {
            title = album.name
        } else {
            title = album.providerMappings?.first?.itemID ?? "Untitled"
        }
        self.init(
            id: MediaID(.album, album.uri), title: title,
            artistID: album.artists?.first.map { MediaID(.artist, $0.uri) },
            artistName: MAMapping.artistNames(album.artists), year: album.year, trackCount: nil,
            artwork: MAMapping.artwork(album.metadata))
        isFavorite = album.favorite
    }
}

extension LibraryTrack {
    init(ma track: MATrack) {
        let format = track.providerMappings?.first?.audioFormat
        let bitRate = format?.bitRate.flatMap { $0 > 0 ? $0 : nil }
        self.init(
            id: MediaID(.track, track.uri), title: track.name,
            artistID: track.artists?.first.map { MediaID(.artist, $0.uri) },
            artistName: MAMapping.artistNames(track.artists) ?? ArtistName.unknown,
            albumID: track.album.map { MediaID(.album, $0.uri) }, albumName: track.album?.name,
            trackNumber: track.trackNumber, discNumber: track.discNumber, duration: track.duration,
            bitrate: bitRate, sampleRate: format?.sampleRate.map(Double.init), channels: format?.channels,
            artwork: MAMapping.artwork(track.metadata) ?? track.album?.image?.proxyID.map { ArtworkRef($0) })
        isFavorite = track.favorite
        playlistPosition = track.position
    }
}

extension LibraryPlaylist {
    /// `canReorder`: the server has `music/playlists/move_playlist_track` (absent on 2.10.6; from the command probe, #0137).
    init(ma playlist: MAPlaylist, canReorder: Bool = false) {
        let isEditable = playlist.isEditable ?? false
        let isDynamic = playlist.isDynamic ?? false
        let source = MAMapping.playlistSource(playlist)
        var editing: PlaylistEditing = []
        if isEditable && !isDynamic {
            editing.insert(.addRemove)
            if canReorder { editing.insert(.reorder) }
        }
        if source != .builtIn { editing.formUnion([.rename, .delete]) }
        self.init(
            id: MediaID(.playlist, playlist.uri), name: playlist.name, trackCount: nil,
            artwork: MAMapping.artwork(playlist.metadata), isEditable: isEditable, isDynamic: isDynamic,
            owner: playlist.owner, source: source, editing: editing, isFavorite: playlist.favorite,
            libraryID: playlist.provider == "library" ? playlist.itemID : nil)
    }
}

extension OutputDevice {
    init(ma player: MAPlayer, groupable: Set<ID>? = nil) {
        let name = player.displayName.flatMap { $0.isEmpty ? nil : $0 } ?? player.name
        // Groups are unrecorded on the reference server: `type == "group"`, or members listed on a typeless player.
        // A `player` with members is a sync leader (#0118), and a `stereo_pair` is one speaker.
        let isGroup = player.type == "group" || (player.type == nil && !(player.groupMembers ?? []).isEmpty)
        self.init(
            id: ID(rawValue: player.playerID), name: name, kind: .remote, isAvailable: player.available, isGroup: isGroup,
            groupableWith: groupable)
    }
}

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
}

extension LibraryArtist {
    init(ma artist: MAArtist) {
        self.init(
            id: MediaID(.artist, artist.uri), name: ArtistName.display(artist.name), sortName: artist.sortName,
            artwork: MAMapping.artwork(artist.metadata))
    }
}

extension LibraryAlbum {
    /// MA stores some albums with an empty name (the folder name is only in the provider mapping); the fallback
    /// to that name, then "Untitled", is SkinAmp's choice. MA's own UI shows a blank.
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
    }
}

extension LibraryPlaylist {
    init(ma playlist: MAPlaylist) {
        self.init(
            id: MediaID(.playlist, playlist.uri), name: playlist.name, trackCount: nil,
            artwork: MAMapping.artwork(playlist.metadata))
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

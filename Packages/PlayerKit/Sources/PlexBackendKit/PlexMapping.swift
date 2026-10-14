import Foundation
import MusicBackendKit
import PlexKit

extension LibraryArtist {
    init(plex artist: PlexArtist) {
        self.init(
            id: MediaID(.artist, artist.ratingKey), name: artist.title, sortName: artist.titleSort,
            artwork: artist.thumb.map { ArtworkRef($0) })
    }
}

extension LibraryAlbum {
    init(plex album: PlexAlbum) {
        self.init(
            id: MediaID(.album, album.ratingKey), title: album.title,
            artistID: album.parentRatingKey.map { MediaID(.artist, $0) }, artistName: album.parentTitle,
            year: album.year, trackCount: album.leafCount,
            artwork: (album.thumb ?? album.parentThumb).map { ArtworkRef($0) })
    }
}

extension LibraryTrack {
    init(plex track: PlexTrack) {
        let media = track.media.first
        self.init(
            id: MediaID(.track, track.ratingKey), title: track.title,
            artistID: track.grandparentRatingKey.map { MediaID(.artist, $0) },
            artistName: track.grandparentTitle ?? "",
            albumID: track.parentRatingKey.map { MediaID(.album, $0) }, albumName: track.parentTitle,
            trackNumber: track.index, discNumber: track.parentIndex, duration: track.durationSeconds,
            bitrate: media?.bitrate, sampleRate: nil, channels: media?.audioChannels,
            artwork: (track.thumb ?? track.parentThumb).map { ArtworkRef($0) })
    }
}

extension Page {
    /// A Plex page as a source-neutral one, mapping each item.
    init<Source: Hashable & Sendable>(plex page: PlexPage<Source>, request: PageRequest, map: (Source) -> Item) {
        self = Page.make(items: page.items.map(map), request: request, total: page.totalSize)
    }
}

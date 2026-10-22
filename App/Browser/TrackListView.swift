import LibraryBrowser
import MusicBackendKit
import SwiftUI

struct TrackRow: View {
    let track: LibraryTrack
    var albumArtist: String?

    var body: some View {
        FavoriteRow(id: track.id, stored: track.isFavorite) {
            row
        }
    }

    private var row: some View {
        HStack(spacing: 10) {
            Text(LibraryFormat.trackNumber(track))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(minWidth: 28, alignment: .trailing)
            VStack(alignment: .leading, spacing: 2) {
                Text(track.title).lineLimit(1)
                if track.artistName != albumArtist {
                    Text(ArtistName.display(track.artistName)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer()
            Text(LibraryFormat.duration(track.duration))
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
    }
}

/// The tracks of the selected album or playlist; a playlist's are `PlaylistTracksView` (#0138).
struct TrackListView: View {
    let library: LibraryBrowserModel
    @Environment(PlayerModel.self) private var player
    @State private var selection = Set<MediaID>()

    private var heading: String {
        library.selectedAlbum?.title ?? library.selectedPlaylist?.name ?? ""
    }

    private var albumArtist: String? { library.selectedAlbum?.artistName }

    /// The playlist shown here, which drops add to (#0136).
    private var openPlaylist: LibraryPlaylist? { library.selectedAlbum == nil ? library.selectedPlaylist : nil }

    var body: some View {
        Group {
            switch library.tracks {
            case .idle:
                Color.clear
            case .loading:
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            case .failed(let message):
                ContentUnavailableView {
                    Label("Couldn't load the tracks", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(message)
                } actions: {
                    Button("Retry") { library.retryTracks() }
                }
            case .loaded(let tracks):
                if tracks.isEmpty {
                    ContentUnavailableView("No tracks", systemImage: "music.note")
                } else {
                    VStack(alignment: .leading, spacing: 0) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(heading).font(.title3.bold()).lineLimit(1)
                            Text(LibraryFormat.trackSummary(count: tracks.count, duration: tracks.reduce(0) { $0 + ($1.duration ?? 0) }))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            if library.selectedAlbum == nil, let playlist = library.selectedPlaylist {
                                HStack(spacing: 4) {
                                    if !playlist.isEditable {
                                        Image(systemName: "lock.fill").accessibilityHidden(true)
                                    }
                                    Text(PlaylistGrouping.detailLine(playlist))
                                }
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .accessibilityIdentifier("library.playlist.detail")
                            }
                        }
                        .padding([.horizontal, .top])
                        .padding(.bottom, 8)
                        if let openPlaylist {
                            PlaylistTracksView(library: library, playlist: openPlaylist, tracks: tracks)
                        } else {
                            List(tracks, selection: $selection) { track in
                                TrackRow(track: track, albumArtist: albumArtist)
                                    .draggable(MediaIDTransfer([track.id]))
                            }
                            .libraryTrackActions(rows: tracks, album: library.selectedAlbum?.id, model: player)
                        }
                    }
                }
            }
        }
        .accessibilityIdentifier("library.tracks")
        .navigationTitle(heading)
    }
}

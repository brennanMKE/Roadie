import LibraryBrowser
import MusicBackendKit
import SwiftUI

/// An open playlist's tracks (#0138): the Delete key and "Remove from Playlist" remove the selection (asking first
/// for 10 or more), drag and Move Up/Down reorder when the server can, and the edit bar shows progress or Retry.
struct PlaylistTracksView: View {
    let library: LibraryBrowserModel
    let playlist: LibraryPlaylist
    let tracks: [LibraryTrack]
    @Environment(PlayerModel.self) private var player
    @State private var selection = Set<MediaID>()
    @State private var confirmRemoving: Set<MediaID>?
    /// The "needs a newer Music Assistant" caption shows until dismissed, once.
    @AppStorage("library.playlists.reorderCaptionDismissed") private var captionDismissed = false

    /// Asking first from this many tracks.
    static let confirmThreshold = 10

    private var editor: PlaylistEditor { library.playlistEditor }

    var body: some View {
        VStack(spacing: 0) {
            if editor.reorderNeedsNewerServer, !captionDismissed {
                HStack(spacing: 6) {
                    Text("Reordering needs a newer Music Assistant.")
                    Spacer()
                    Button("OK") { captionDismissed = true }.buttonStyle(.link)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal)
                .padding(.bottom, 4)
                .accessibilityIdentifier("library.playlist.reorderCaption")
            }
            List(selection: $selection) {
                ForEach(tracks) { track in
                    TrackRow(track: track)
                        .libraryDraggable([track.id])
                        .accessibilityIdentifier(AXID.Library.row("track", track.id.rawValue))
                }
                .onMove(perform: editor.canReorder ? { source, destination in
                    editor.move(from: source, to: destination)
                } : nil)
            }
            .libraryTrackActions(
                rows: tracks, album: nil, model: player, editor: editor, remove: { askToRemove($0) })
            .addsDroppedItems(to: playlist, model: player)
            .onDeleteCommand { askToRemove(selection) }
            .confirmationDialog(
                confirmTitle, isPresented: Binding(
                    get: { confirmRemoving != nil }, set: { if !$0 { confirmRemoving = nil } }),
                titleVisibility: .visible
            ) {
                Button("Remove", role: .destructive) {
                    if let ids = confirmRemoving { remove(ids) }
                    confirmRemoving = nil
                }
                Button("Cancel", role: .cancel) { confirmRemoving = nil }
            }
            PlaylistEditBar(editor: editor)
        }
        .onChange(of: tracks.map(\.id)) { _, ids in
            // A removed row's selection goes with it.
            selection.formIntersection(ids)
        }
    }

    private var confirmTitle: String {
        "Remove \(confirmRemoving?.count ?? 0) tracks from \u{201C}\(playlist.name)\u{201D}?"
    }

    private func askToRemove(_ ids: Set<MediaID>) {
        guard !ids.isEmpty, editor.canRemove else { return }
        if ids.count >= Self.confirmThreshold {
            confirmRemoving = ids
        } else {
            remove(ids)
        }
    }

    private func remove(_ ids: Set<MediaID>) {
        editor.remove(selected: ids)
        selection.subtract(ids)
    }
}

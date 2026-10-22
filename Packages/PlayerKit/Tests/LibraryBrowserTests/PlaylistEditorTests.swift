import Foundation
import MusicBackendKit
import MusicBackendStub
import Testing
@testable import LibraryBrowser

@MainActor
struct PlaylistEditorTests {
    /// An editor with the stub's first playlist open (5 tracks).
    func openEditor(_ editing: PlaylistEditing = [.addRemove, .rename, .delete]) async throws
        -> (StubMusicBackend, PlaylistEditor, LibraryPlaylist, [LibraryTrack])
    {
        var library = StubLibrary.sample(playlistCount: 1)
        library.playlists[0].isEditable = true
        library.playlists[0].editing = editing
        let playlist = library.playlists[0]
        library.playlistTracks[playlist.id] = Array(library.tracks.prefix(5).map(\.id))
        let backend = StubMusicBackend(library: library, capabilities: [.playlists, .playlistEditing])
        let rows = try await backend.tracks(ofPlaylist: playlist.id)
        let editor = PlaylistEditor(backend: backend, refetchFallback: .seconds(60))
        editor.open(playlist, rows: rows)
        return (backend, editor, playlist, rows)
    }

    @Test func removeAppliesAtOnceAndSends() async throws {
        let (backend, editor, playlist, rows) = try await openEditor()
        await backend.gate(.removeFromPlaylist)
        let task = try #require(editor.remove(selected: [rows[1].id, rows[3].id]))
        #expect(editor.rows.map(\.id) == [rows[0].id, rows[2].id, rows[4].id])
        #expect(editor.rows.map(\.playlistPosition) == [1, 2, 3])
        #expect(editor.pending == .removing(2))
        await backend.release(.removeFromPlaylist)
        await task.value
        #expect(await backend.calls(.removeFromPlaylist) == [.removeFromPlaylist([4, 2], playlist.id)])
        #expect(editor.pending == nil)
        #expect(editor.error == nil)
        #expect(await backend.library.playlistTracks[playlist.id] == editor.rows.map(\.id))
    }

    @Test func removeRollsBackOnFailure() async throws {
        let (backend, editor, _, rows) = try await openEditor()
        await backend.setError(.backend("The server said no."), for: .removeFromPlaylist)
        await editor.remove(selected: [rows[0].id])?.value
        #expect(editor.rows == rows)
        #expect(editor.pending == nil)
        #expect(editor.error == "The server said no.")

        await backend.setError(nil, for: .removeFromPlaylist)
        editor.retry()
        #expect(editor.error == nil)
        #expect(await waitFor { await backend.count(.removeFromPlaylist) == 2 })
        #expect(await waitFor { editor.pending == nil })
        #expect(editor.rows.map(\.id) == Array(rows.dropFirst().map(\.id)))
    }

    @Test func editsRunInOrder() async throws {
        let (backend, editor, playlist, rows) = try await openEditor()
        await editor.remove(selected: [rows[0].id])?.value
        // Renumbered locally: the old position 4 is now 3.
        await editor.remove(selected: [rows[3].id])?.value
        #expect(await backend.calls(.removeFromPlaylist) == [
            .removeFromPlaylist([1], playlist.id), .removeFromPlaylist([3], playlist.id),
        ])
        #expect(await backend.library.playlistTracks[playlist.id] == [rows[1].id, rows[2].id, rows[4].id])
        #expect(editor.rows.map(\.id) == [rows[1].id, rows[2].id, rows[4].id])
    }

    @Test func staleRefetchIsDropped() async throws {
        let (backend, editor, playlist, rows) = try await openEditor()
        await backend.gate(.playlistTracks)
        editor.reloadIfOpen(playlist.id)
        #expect(await waitFor { await backend.suspendedCount == 1 })
        // An edit after the refetch started makes its answer stale.
        await editor.remove(selected: [rows[0].id])?.value
        var library = await backend.library
        library.playlistTracks[playlist.id] = []
        await backend.setLibrary(library)
        await backend.release(.playlistTracks)
        #expect(await waitFor { await backend.suspendedCount == 0 })
        try await Task.sleep(for: .milliseconds(50))
        #expect(editor.rows.map(\.id) == Array(rows.dropFirst().map(\.id)))

        // A refetch with nothing newer lands.
        editor.reloadIfOpen(playlist.id)
        #expect(await waitFor { editor.rows.isEmpty })
    }

    @Test func moveIsRefusedWithoutReorder() async throws {
        let (backend, editor, _, rows) = try await openEditor()
        #expect(!editor.canReorder)
        #expect(editor.reorderNeedsNewerServer)
        #expect(editor.move(from: [0], to: 3) == nil)
        #expect(editor.moveDown(rows[0].id) == nil)
        #expect(editor.rows == rows)
        #expect(await backend.count(.movePlaylistTrack) == 0)

        let (reorderable, editorWithReorder, playlist, ordered) = try await openEditor([.addRemove, .reorder])
        #expect(!editorWithReorder.reorderNeedsNewerServer)
        await editorWithReorder.move(from: [0], to: 3)?.value
        #expect(editorWithReorder.rows.map(\.id) == [ordered[1].id, ordered[2].id, ordered[0].id, ordered[3].id, ordered[4].id])
        #expect(await reorderable.calls(.movePlaylistTrack) == [.movePlaylistTrack(playlist.id, 1, 3)])
        await editorWithReorder.moveUp(ordered[4].id)?.value
        #expect(await reorderable.calls(.movePlaylistTrack).last == .movePlaylistTrack(playlist.id, 5, 4))
    }

    @Test func pendingBlocksASecondStructuralEdit() async throws {
        let (backend, editor, _, rows) = try await openEditor([.addRemove, .reorder])
        await backend.gate(.removeFromPlaylist)
        let first = try #require(editor.remove(selected: [rows[0].id]))
        #expect(!editor.canRemove)
        #expect(!editor.canReorder)
        #expect(editor.remove(selected: [rows[1].id]) == nil)
        #expect(editor.moveDown(rows[1].id) == nil)
        await backend.release(.removeFromPlaylist)
        await first.value
        #expect(await backend.count(.removeFromPlaylist) == 1)
        #expect(editor.canRemove)
        #expect(editor.remove(selected: [rows[1].id]) != nil)
    }
}

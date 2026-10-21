import Foundation
import MusicBackendKit
import MusicBackendStub
import Testing
@testable import LibraryBrowser

@MainActor
struct PlaylistsModelTests {
    /// Connected, on the Playlists section with its list loaded.
    func connectedOnPlaylists() async -> (StubMusicBackend, LibraryBrowserModel) {
        var library = StubLibrary.sample(playlistCount: 3)
        for index in library.playlists.indices {
            library.playlists[index].isEditable = true
            library.playlists[index].editing = [.addRemove, .rename, .delete]
            library.playlists[index].libraryID = library.playlists[index].id.rawValue
        }
        let (backend, model) = makeModel(library: library, capabilities: [.search, .playlists, .playlistEditing])
        model.appeared()
        #expect(await waitFor { model.connection == .connected })
        model.section = .playlists
        #expect(await waitFor { model.playlists.phase == .loaded })
        return (backend, model)
    }

    @Test func createInsertsAndSelects() async throws {
        let (backend, model) = await connectedOnPlaylists()
        let created = try #require(await model.playlistsModel.create(named: "  Road Trip "))
        #expect(created.name == "Road Trip")
        #expect(model.playlists.items.first?.id == created.id)
        #expect(model.selectedPlaylist?.id == created.id)
        #expect(await backend.calls(.createPlaylist) == [.createPlaylist("Road Trip")])
        #expect(await model.playlistsModel.create(named: "   ") == nil)
        #expect(await backend.count(.createPlaylist) == 1)
    }

    @Test func renameRollsBackOnFailure() async throws {
        let (backend, model) = await connectedOnPlaylists()
        let editor = model.playlistsModel
        let playlist = model.playlists.items[1]
        model.select(playlist)

        #expect(await editor.rename(playlist, to: "Sunday"))
        #expect(model.playlists.items[1].name == "Sunday")
        #expect(model.selectedPlaylist?.name == "Sunday")

        await backend.setError(.forbidden("Missing scope library.manage"), for: .renamePlaylist)
        let renamed = model.playlists.items[1]
        #expect(await !editor.rename(renamed, to: "Monday"))
        #expect(model.playlists.items[1].name == "Sunday")
        #expect(model.selectedPlaylist?.name == "Sunday")
        #expect(editor.message == "Missing scope library.manage")
        #expect(!editor.canRename(renamed))
        #expect(editor.refusal(for: renamed) == "Missing scope library.manage")
    }

    @Test func deleteRollsBackOnFailure() async throws {
        let (backend, model) = await connectedOnPlaylists()
        let editor = model.playlistsModel
        let playlist = model.playlists.items[1]
        model.select(playlist)

        await backend.setError(.unreachable("Can't reach Music Assistant"), for: .deletePlaylist)
        #expect(await !editor.delete(playlist))
        #expect(model.playlists.items.map(\.id)[1] == playlist.id)
        #expect(model.playlists.items.count == 3)
        #expect(model.selectedPlaylist?.id == playlist.id)
        #expect(editor.message == "Can't reach Music Assistant")

        await backend.setError(nil, for: .deletePlaylist)
        #expect(await editor.delete(playlist))
        #expect(!model.playlists.items.contains { $0.id == playlist.id })
        #expect(model.selectedPlaylist == nil)
        #expect(await backend.calls(.deletePlaylist) == [.deletePlaylist(playlist.id), .deletePlaylist(playlist.id)])
    }

    @Test func builtInPlaylistsCanNotBeRenamedOrDeleted() async {
        let (_, model) = await connectedOnPlaylists()
        let builtIn = LibraryPlaylist(id: MediaID(.playlist, "b1"), name: "Random", source: .builtIn)
        #expect(!model.playlistsModel.canRename(builtIn))
        #expect(!model.playlistsModel.canDelete(builtIn))
        model.playlistsModel.askToDelete(builtIn)
        #expect(model.playlistsModel.pendingDelete == nil)
    }

    @Test func addRecordsRecentTarget() async throws {
        let (backend, model) = await connectedOnPlaylists()
        let defaults = try #require(UserDefaults(suiteName: "PlaylistsModelTests.\(UUID().uuidString)"))
        let editor = PlaylistsModel(backend: backend, list: model.playlists, defaults: defaults)
        let first = model.playlists.items[0], second = model.playlists.items[2]
        let track = try #require(await backend.library.tracks.first?.id)

        #expect(await editor.add([track], to: second) == "Added 1 track to \(second.name)")
        #expect(await editor.add([track], to: first) == "Added 1 track to \(first.name)")
        #expect(editor.recentTargets == [first.id, second.id])
        #expect(await backend.calls(.addToPlaylist) == [.addToPlaylist([track], second.id), .addToPlaylist([track], first.id)])
        #expect(editor.addEntries(excluding: nil).prefix(2) == [.playlist(first), .playlist(second)])
        // Kept across launches.
        #expect(PlaylistsModel(backend: backend, list: model.playlists, defaults: defaults).recentTargets == [first.id, second.id])

        await backend.setError(.forbidden("Read-only"), for: .addToPlaylist)
        #expect(await editor.add([track], to: second) == "Read-only")
        #expect(editor.recentTargets == [first.id, second.id])
    }
}

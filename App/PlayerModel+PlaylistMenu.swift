import AudioCore
import LibraryBrowser
import MusicBackendKit
import SkinKit

/// The playlist editor's commands (#0226): their state, and one exhaustive switch from a command onto the model. The
/// skinned ADD/REM/SEL/MISC/LIST entries, their SORT and MISC OPTIONS pop-ups and the menu bar's Playlist menu run
/// through here. Reads observed properties only, so the menu bar's enabled states follow without a refresh.
extension PlayerModel {
    var playlistMenuState: PlaylistMenuState {
        let playlist = playlist
        let tracks = playlist.tracks
        let output = selectedOutput
        let loads = QueueSaveTarget.loadChoices(
            output: output, feed: thisMacFeed, capabilities: router.backend(for: output).capabilities,
            libraryHasPlaylists: canLoadLibraryPlaylist)
        return PlaylistMenuState(
            hasRows: !tracks.isEmpty, hasSelection: tracks.contains { playlist.selection.contains($0) },
            isRemote: playlist.remote != nil, canAddURL: library.sections.contains(.radio),
            hasFileInfo: playlist.fileInfoTrack != nil, canSave: canSaveQueue, canLoad: !loads.isEmpty)
    }

    func perform(_ command: PlaylistCommand) {
        let playlist = playlist
        switch command {
        case .addFile: openFiles(replace: false)
        case .addFolder: openFolder()
        // With a radio-capable source (Music Assistant), Add URL adds a radio station (#0147); otherwise nothing.
        case .addURL:
            if library.sections.contains(.radio) {
                library.section = .radio
                library.isAddingRadio = true
                openWindowAction?(id: "library")
            }
        case .removeSelected: playlist.removeSelected()
        case .crop: playlist.crop()
        case .clearPlaylist: playlist.removeAll()
        case .selectAll: playlist.selectAll()
        case .selectNone: playlist.selectNone()
        case .invertSelection: playlist.invertSelection()
        case .sortByTitle: playlist.sortByTitle()
        case .sortByFileName: playlist.sortByFileName()
        case .sortByPath: playlist.sortByPath()
        case .reverse: playlist.reverse()
        case .randomize: playlist.randomize()
        case .fileInfo: if let track = playlist.fileInfoTrack { showFileInfo(for: track) }
        case .generateHTML: generateHTMLPlaylist()
        case .loadPlaylist: loadList()
        case .savePlaylist: saveQueue()
        }
    }
}

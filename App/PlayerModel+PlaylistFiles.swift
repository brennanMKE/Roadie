import AppKit
import AudioCore
import Foundation
import LibraryBrowser
import MusicBackendKit
import UniformTypeIdentifiers

/// The playlist window's LIST › Save List / Load List and the File menu's playlist items (#0082).
extension PlayerModel {
    /// LIST › Load (#0146, #0190): the shown queue decides, like Save (`QueueSaveTarget`). The local queue opens a
    /// playlist file, or a Library playlist when the Library's source has them; a Music Assistant queue picks one of
    /// its playlists.
    func loadList() {
        let output = selectedOutput
        let choices = QueueSaveTarget.loadChoices(
            output: output, feed: thisMacFeed, capabilities: router.backend(for: output).capabilities,
            libraryHasPlaylists: canLoadLibraryPlaylist)
        switch choices {
        case []: post(StatusNotice(text: "Can't load a playlist", detail: "This music source has no playlists"))
        case [.file]: loadPlaylistFile()
        case [.libraryPlaylist]: pickLibraryPlaylist()
        default:
            PlaylistContextMenus.popUp([
                ("Library Playlist\u{2026}", { [weak self] in self?.pickLibraryPlaylist() }),
                ("Playlist File\u{2026}", { [weak self] in self?.loadPlaylistFile() }),
            ])
        }
    }

    /// The Library's selected source has playlists (#0190).
    var canLoadLibraryPlaylist: Bool { backend.capabilities.contains(.playlists) }

    /// Opens the playlist picker; it's attached to the playlist editor, so that opens first.
    func pickLibraryPlaylist() {
        library.loadPlaylistsIfNeeded()
        if !isPlaylistWindowOpen { setPlaylistWindowOpen(true) }
        isPickingPlaylist = true
    }

    /// Plays a Music Assistant playlist, replacing the shown queue.
    func loadPlaylist(_ playlist: LibraryPlaylist) {
        playFromLibrary(PlayRequest(items: [playlist.id], mode: .replace()))
    }

    /// Single playlist file; replaces the queue and plays, like File › Open.
    func loadPlaylistFile() {
        if let text = LocalPlaybackGate.refusal(forLocalFilesOn: outputSelection) {
            post(StatusNotice(text: text))
            return
        }
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = LocalTrackLoader.playlistTypes
        panel.message = "Choose a playlist"
        panel.prompt = "Load"
        Task {
            guard await panel.begin() == .OK, let url = panel.url else { return }
            importLocalFiles([url], replace: true)
        }
    }

    /// Writes the queue's local files as M3U8, M3U or PLS (chosen in the panel's popup, or by the typed extension).
    func savePlaylistFile() {
        let tracks = player.queue.tracks
        guard !tracks.isEmpty else {
            post(StatusNotice(text: "Nothing to save"))
            return
        }
        let panel = NSSavePanel()
        let chooser = PlaylistFormatChooser(panel: panel)
        panel.accessoryView = chooser.view
        panel.nameFieldStringValue = "Playlist.m3u8"
        panel.message = "Save the playlist"
        panel.prompt = "Save"
        Task {
            let response = await panel.begin()
            withExtendedLifetime(chooser) {}
            guard response == .OK, let url = panel.url else { return }
            let format: PlaylistFile.Format = url.pathExtension.lowercased() == "pls" ? .pls : .m3u
            let out = PlaylistFile.serialize(tracks, format: format, playlistURL: url)
            guard out.written > 0 else {
                post(StatusNotice(text: "Nothing to save", detail: "The playlist has no local files"))
                return
            }
            do {
                try out.data.write(to: url, options: .atomic)
            } catch {
                post(StatusNotice(text: "Could not save \(url.lastPathComponent)", detail: error.localizedDescription))
                return
            }
            if out.skipped > 0 {
                post(StatusNotice(
                    text: "Saved \(out.written), skipped \(out.skipped) server tracks",
                    detail: "Server tracks have no local file"))
            } else {
                post(StatusNotice(text: "Saved \(out.written) track\(out.written == 1 ? "" : "s")"))
            }
        }
    }
}

/// The Library's playlist context menu: M3U8 export and import through Music Assistant (#0148).
extension PlayerModel {
    /// Saves the server's M3U8 for `playlist`; its entries are paths and URIs on the server.
    func exportLibraryPlaylist(_ playlist: LibraryPlaylist) {
        let model = library.playlistsModel
        Task {
            guard let text = await model.exportM3U(playlist) else { return }
            let panel = NSSavePanel()
            panel.allowedContentTypes = [UTType(filenameExtension: "m3u8", conformingTo: .data) ?? .data]
            panel.nameFieldStringValue = playlist.name + ".m3u8"
            panel.message = "Entries refer to paths and URIs on the Music Assistant server"
            panel.prompt = "Export"
            guard await panel.begin() == .OK, let url = panel.url else { return }
            do {
                try Data(text.utf8).write(to: url, options: .atomic)
                post(StatusNotice(text: "Exported \u{201C}\(playlist.name)\u{201D}"))
            } catch {
                post(StatusNotice(text: "Could not save \(url.lastPathComponent)", detail: error.localizedDescription))
            }
        }
    }

    /// Sends an M3U/M3U8 file to Music Assistant, which makes a new playlist and matches entries to the library.
    func importLibraryPlaylist() {
        let model = library.playlistsModel
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = ["m3u8", "m3u"].compactMap { UTType(filenameExtension: $0, conformingTo: .data) }
        panel.message = "Choose an M3U playlist to import into Music Assistant"
        panel.prompt = "Import"
        Task {
            guard await panel.begin() == .OK, let url = panel.url else { return }
            let text: String
            do {
                let data = try Data(contentsOf: url)
                text = String(decoding: data, as: UTF8.self)
            } catch {
                post(StatusNotice(text: "Could not read \(url.lastPathComponent)", detail: error.localizedDescription))
                return
            }
            if let created = await model.importM3U(text) {
                post(StatusNotice(text: "Imported \u{201C}\(created.name)\u{201D}"))
            }
        }
    }
}

/// The save panel's format popup. Changing it sets `allowedContentTypes`, which rewrites the name's extension.
@MainActor
private final class PlaylistFormatChooser: NSObject {
    private static let choices: [(title: String, ext: String)] = [
        ("M3U8 playlist", "m3u8"), ("M3U playlist", "m3u"), ("PLS playlist", "pls"),
    ]

    let view: NSView
    private weak var panel: NSSavePanel?
    private let popup: NSPopUpButton

    init(panel: NSSavePanel) {
        self.panel = panel
        popup = NSPopUpButton(frame: .zero, pullsDown: false)
        popup.addItems(withTitles: Self.choices.map(\.title))
        let label = NSTextField(labelWithString: "Format:")
        let stack = NSStackView(views: [label, popup])
        stack.orientation = .horizontal
        stack.edgeInsets = NSEdgeInsets(top: 8, left: 16, bottom: 8, right: 16)
        stack.frame = NSRect(origin: .zero, size: stack.fittingSize)
        view = stack
        super.init()
        popup.target = self
        popup.action = #selector(formatChanged)
        apply(index: 0)
    }

    @objc private func formatChanged() { apply(index: popup.indexOfSelectedItem) }

    private func apply(index: Int) {
        guard Self.choices.indices.contains(index),
              let type = UTType(filenameExtension: Self.choices[index].ext, conformingTo: .data) else { return }
        panel?.allowedContentTypes = [type]
    }
}

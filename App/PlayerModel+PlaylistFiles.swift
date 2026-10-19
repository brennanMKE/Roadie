import AppKit
import AudioCore
import Foundation
import UniformTypeIdentifiers

/// The playlist window's LIST › Save List / Load List and the File menu's playlist items (#0082).
extension PlayerModel {
    /// Single playlist file; replaces the queue and plays, like File › Open.
    func loadPlaylistFile() {
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
                post(StatusNotice(text: "Nothing to save", detail: "Plex tracks have no local file"))
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
                    detail: "Plex tracks have no local file"))
            } else {
                post(StatusNotice(text: "Saved \(out.written) track\(out.written == 1 ? "" : "s")"))
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

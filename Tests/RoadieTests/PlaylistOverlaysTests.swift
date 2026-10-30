import AppKit
import AudioCore
import Foundation
import MusicBackendKit
import PlayerKitTestFixtures
import SkinKit
import XCTest

@testable import Roadie

/// The drop side of `PlaylistListInputView` (#0218): `dragOperation(pasteboard:mask:)` and `performDrop(pasteboard:at:)`,
/// which the `NSDraggingDestination` methods call, and the drop cue, over uniquely named pasteboards (never the drag pasteboard) and a
/// plain `NSView` container: no window, no window-server events.
@MainActor
final class PlaylistOverlaysTests: PlayerModelTestCase {
    private var pasteboards: [NSPasteboard] = []

    override func tearDown() async throws {
        for pasteboard in pasteboards { pasteboard.releaseGlobally() }
        pasteboards = []
        try await super.tearDown()
    }

    private func makePasteboard() -> NSPasteboard {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("roadie.tests.\(UUID())"))
        pasteboard.clearContents()
        pasteboards.append(pasteboard)
        return pasteboard
    }

    private func filePasteboard(_ urls: [URL]) -> NSPasteboard {
        let pasteboard = makePasteboard()
        XCTAssertTrue(pasteboard.writeObjects(urls.map { $0 as NSURL }))
        return pasteboard
    }

    private func mediaIDPasteboard(_ data: Data) -> NSPasteboard {
        let pasteboard = makePasteboard()
        let item = NSPasteboardItem()
        XCTAssertTrue(item.setData(data, forType: LibraryDropDecoder.mediaIDType))
        XCTAssertTrue(pasteboard.writeObjects([item]))
        return pasteboard
    }

    /// The list view in a plain container, sized like the default playlist's track area.
    private func listView(_ model: PlayerModel, option: Bool = false) -> PlaylistListInputView {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 550, height: 400))
        let view = PlaylistListInputView(model: model)
        view.frame = container.bounds
        container.addSubview(view)
        view.isOptionDown = { option }
        return view
    }

    /// The middle of `row` in the container's (window-less, unflipped) coordinates, which `performDrop` takes as the
    /// window point. The view is flipped and fills the container, so skin-y runs down from its top.
    private func point(ofRow row: Int, in view: PlaylistListInputView, _ model: PlayerModel) -> NSPoint {
        let skinY = (CGFloat(row - model.playlist.visibleRange.lowerBound) + 0.5) * PlaylistLayout.rowHeight
        return NSPoint(x: 10, y: view.frame.height - skinY * model.scale)
    }

    func testDropOperationByPasteboard() throws {
        let model = try makeModel()
        let view = listView(model)
        let files = filePasteboard([AudioFixtures.url(.toneAmp3)])
        let ids = mediaIDPasteboard(try JSONEncoder().encode(MediaIDTransfer([MediaID(.album, "A/B")])))
        let empty = makePasteboard()

        XCTAssertEqual(view.dragOperation(pasteboard: files, mask: .copy), .copy)
        XCTAssertNil(model.playlist.dropCue, "no cue without ⌥")
        XCTAssertEqual(view.dragOperation(pasteboard: ids, mask: .copy), .copy)
        XCTAssertEqual(view.dragOperation(pasteboard: ids, mask: .move), .move, "the source's only operation")
        XCTAssertEqual(view.dragOperation(pasteboard: empty, mask: .copy), [])
        XCTAssertFalse(view.performDrop(pasteboard: empty, at: .zero), "nothing to drop")

        // ⌥ held: the replace cue, cleared when the drag leaves, ends or is performed.
        let replacing = listView(model, option: true)
        XCTAssertEqual(replacing.dragOperation(pasteboard: files, mask: .copy), .copy)
        XCTAssertEqual(model.playlist.dropCue, .replace)
        replacing.draggingExited(nil)
        XCTAssertNil(model.playlist.dropCue)
        XCTAssertEqual(replacing.dragOperation(pasteboard: ids, mask: .copy), .copy)
        XCTAssertEqual(model.playlist.dropCue, .replace)
        replacing.clearDropCue()
        XCTAssertNil(model.playlist.dropCue)
        _ = replacing.dragOperation(pasteboard: files, mask: .copy)
        XCTAssertFalse(replacing.performDrop(pasteboard: empty, at: .zero))
        XCTAssertNil(model.playlist.dropCue, "a drop clears the cue")
        _ = replacing.dragOperation(pasteboard: files, mask: .copy)
        replacing.concludeDragOperation(nil)
        XCTAssertNil(model.playlist.dropCue)
    }

    func testDropReachesModel() async throws {
        let model = try makeModel(folder: true)
        let albums = try await folderAlbums(model)
        let album = try XCTUnwrap(albums.first { $0.title == AudioFixtures.album })
        restoreThreeTracks(model)
        let view = listView(model)

        // Files go into the local queue; it already has tracks, so nothing plays.
        // Dropped on row 1's middle: inserted before it, in pasteboard order.
        XCTAssertTrue(model.playlist.visibleRange.contains(1))
        let files = [AudioFixtures.url(.toneDalac), AudioFixtures.url(.toneFwav)]
        XCTAssertTrue(view.performDrop(pasteboard: filePasteboard(files), at: point(ofRow: 1, in: view, model)))
        try await waitUntil("the dropped files") { model.player.queue.tracks.count == 5 }
        let names = model.player.queue.tracks.map { track in
            switch track.source {
            case .file(let url): url.lastPathComponent
            }
        }
        XCTAssertEqual(names, ["Tone A.mp3", "04 Tone D.m4a", "06 Tone F.wav", "Tone B.mp3", "Tone C.mp3"])
        XCTAssertEqual(model.player.state, .stopped)

        // A Library album goes through the folder backend.
        let ids = mediaIDPasteboard(try JSONEncoder().encode(MediaIDTransfer([album.id])))
        XCTAssertTrue(view.performDrop(pasteboard: ids, at: .zero))
        try await waitUntil("the dropped album") { model.player.queue.tracks.count == 8 }

        // Media-id data that doesn't decode: refused with a notice, the queue unchanged.
        let junk = mediaIDPasteboard(Data("not json".utf8))
        XCTAssertFalse(view.performDrop(pasteboard: junk, at: .zero))
        XCTAssertEqual(model.notice?.text, "Couldn't read the dragged items")
        XCTAssertEqual(model.player.queue.tracks.count, 8)
        XCTAssertNil(model.playlist.dropCue)
    }
}

import AudioCore
import Foundation
import MusicBackendKit
import SkinKit
import XCTest

@testable import Roadie

/// `PlaylistModel` (#0210): the rows, playing a row (#0187), Queue (Q), edits and scrolling, on the local queue and on
/// a remote (Music Assistant) queue. The model is built on a bare `Player` and a throwaway defaults suite, with
/// recorders for the closures `PlayerModel.init` sets. Nothing plays: the tracks point at files that don't exist, and
/// a row that starts loading is stopped before the load can land.
@MainActor
final class PlaylistModelTests: XCTestCase {
    private var suiteName = ""
    private var player: Player!
    private var model: PlaylistModel!
    private var isLocal = true
    private var playLocalCount = 0
    private var remotePlays: [Int] = []
    private var refusedCount = 0
    private var remoteEdits: [QueueEdit] = []
    private var notices: [String] = []

    override func setUp() async throws {
        suiteName = "co.sstools.roadie.tests.playlist.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        player = Player()
        model = PlaylistModel(player: player, defaults: defaults)
        isLocal = true
        playLocalCount = 0
        remotePlays = []
        refusedCount = 0
        remoteEdits = []
        notices = []
        model.isLocal = { [unowned self] in self.isLocal }
        model.isPlayingLocalQueue = { true }
        model.onPlayLocal = { [unowned self] in self.playLocalCount += 1 }
        model.onPlayRemote = { [unowned self] in self.remotePlays.append($0) }
        model.onRemoteRefused = { [unowned self] in self.refusedCount += 1 }
        model.onEditRemote = { [unowned self] in self.remoteEdits.append($0) }
        model.onRemoteNotice = { [unowned self] in self.notices.append($0) }
        // Room for every row of the small queues below.
        model.setSteps(PlaylistLayout.Steps(width: 0, height: 10))
    }

    override func tearDown() async throws {
        player?.stop()
        UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName)
        model = nil
        player = nil
    }

    // MARK: Helpers

    private static let letters = ["A", "B", "C", "D", "E", "F", "G", "H"]

    /// `count` tracks "Artist - Tone A"… with durations 61 s, 62 s, … at nonexistent paths.
    private func makeTracks(_ count: Int) -> [Track] {
        (0..<count).map { i in
            let name = i < Self.letters.count ? Self.letters[i] : "\(i)"
            return Track(
                title: "Tone \(name)", artist: "Artist", duration: TimeInterval(61 + i),
                source: .file(URL(fileURLWithPath: "/nonexistent/roadie-tests/\(name).mp3")))
        }
    }

    @discardableResult
    private func loadLocal(_ count: Int, current: Int? = nil) -> [Track] {
        let tracks = makeTracks(count)
        player.restoreQueue(tracks, currentIndex: current, repeatMode: .off, isShuffled: false)
        return tracks
    }

    /// Music Assistant sends `index` 0 on every row (#0187), so the snapshot's items do too.
    private func remoteSnapshot(_ count: Int, current: Int? = nil) -> RemoteQueueSnapshot {
        RemoteQueueSnapshot(
            output: OutputDevice.ID(rawValue: "speaker"),
            items: (0..<count).map { RemoteQueueItem(id: "q\($0)", index: 0, title: "Remote \($0)", artist: "Band", duration: 100) },
            currentIndex: current)
    }

    private var titles: [String] { model.tracks.map(\.title) }

    /// Waits (up to 2 s) for the chained remote edits to reach the recorder.
    private func waitForRemoteEdits(_ count: Int) async {
        for _ in 0..<200 where remoteEdits.count < count { try? await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(remoteEdits.count, count, "\(remoteEdits)")
    }

    // MARK: Rows

    func testRowsNumberNameMarkerDuration() {
        let tracks = loadLocal(5, current: 2)
        player.toggleUpNext([tracks[3].id, tracks[1].id])
        let rows = model.rows
        XCTAssertEqual(rows.map(\.index), [0, 1, 2, 3, 4])
        XCTAssertEqual(rows.map(\.number), ["1. ", "2. ", "3. ", "4. ", "5. "])
        XCTAssertEqual(rows.map(\.name), ["Artist - Tone A", "Artist - Tone B", "Artist - Tone C", "Artist - Tone D", "Artist - Tone E"])
        XCTAssertEqual(rows.map(\.marker), ["", "[2]", "", "[1]", ""])
        XCTAssertEqual(rows.map(\.duration), ["1:01", "1:02", "1:03", "1:04", "1:05"])
        XCTAssertEqual(rows.map(\.isCurrent), [false, false, true, false, false])
        XCTAssertEqual(rows.map(\.position), [0, 1, 2, 3, 4])
    }

    // MARK: Playing a row (#0187)

    func testPlayRowLocalSelectsTheRow() {
        loadLocal(5)
        model.playRow(3)
        XCTAssertEqual(playLocalCount, 1)
        XCTAssertEqual(player.queue.currentIndex, 3)
        XCTAssertTrue(remotePlays.isEmpty)
    }

    /// The unit-level #0187 guard: every remote item has `index` 0, so playing by the item's index would always send 0.
    func testPlayRowRemoteSendsTheRowNumber() {
        model.remote = remoteSnapshot(5)
        model.playRow(3)
        XCTAssertEqual(remotePlays, [3])
        model.playRow(9)
        XCTAssertEqual(remotePlays, [3], "a row past the end sends nothing")
        XCTAssertEqual(playLocalCount, 0)
    }

    func testPlayFirstSelectedUsesTheLowestSelectedRow() {
        loadLocal(5)
        model.click(3)
        model.commandClick(1)
        model.commandClick(4)
        model.playFirstSelected()
        XCTAssertEqual(player.queue.currentIndex, 1)
        XCTAssertEqual(playLocalCount, 1)
    }

    func testPlayRowIgnoredWhenNotLocal() {
        loadLocal(5)
        isLocal = false
        model.playRow(2)
        XCTAssertEqual(playLocalCount, 0)
        XCTAssertNil(player.queue.currentIndex)
        XCTAssertTrue(remotePlays.isEmpty)
        XCTAssertTrue(model.rows.isEmpty, "a speaker without a listed queue shows no rows")
    }

    // MARK: Queue (Q)

    func testToggleQueueAddsAndRemovesMarkers() {
        loadLocal(5)
        model.toggleQueue([3, 1])
        XCTAssertEqual(model.rows.map(\.marker), ["", "[2]", "", "[1]", ""])
        XCTAssertTrue(model.hasUpNext)
        model.toggleQueue([3])
        XCTAssertEqual(model.rows.map(\.marker), ["", "[1]", "", "", ""])
        model.toggleQueue([1])
        XCTAssertEqual(model.rows.map(\.marker), ["", "", "", "", ""])
        XCTAssertFalse(model.hasUpNext)
        XCTAssertEqual(playLocalCount, 0, "queueing doesn't play")
    }

    func testClearUpNext() {
        loadLocal(5)
        model.toggleQueue([0, 2, 4])
        XCTAssertTrue(model.hasUpNext)
        model.clearUpNext()
        XCTAssertFalse(model.hasUpNext)
        XCTAssertTrue(player.queue.upNext.isEmpty)
    }

    func testSelectionIsQueued() {
        loadLocal(5)
        model.click(1)
        model.commandClick(2)
        XCTAssertFalse(model.selectionIsQueued)
        model.toggleQueue([1])
        XCTAssertFalse(model.selectionIsQueued, "only one of the two is queued")
        model.toggleQueueForSelection()
        XCTAssertTrue(model.selectionIsQueued, "toggling a partly queued selection queues the rest")
        model.toggleQueueForSelection()
        XCTAssertFalse(model.selectionIsQueued)
        model.toggleQueueForSelection()
        XCTAssertTrue(model.selectionIsQueued)
        model.remote = remoteSnapshot(5)
        XCTAssertFalse(model.selectionIsQueued, "a remote queue has no local markers")
    }

    // MARK: Edits

    func testRemoveSelectedCropAndRemoveAll() {
        loadLocal(5)
        model.click(1)
        model.commandClick(3)
        model.removeSelected()
        XCTAssertEqual(titles, ["Tone A", "Tone C", "Tone E"])
        model.click(0)
        model.commandClick(2)
        model.crop()
        XCTAssertEqual(titles, ["Tone A", "Tone E"])
        model.selectNone()
        model.crop()
        XCTAssertEqual(titles, ["Tone A", "Tone E"], "crop with nothing selected keeps everything")
        model.removeAll()
        XCTAssertTrue(titles.isEmpty)
        XCTAssertEqual(model.scrollPosition, 0)
        XCTAssertTrue(remoteEdits.isEmpty)
    }

    func testRemoveSelectedCropAndRemoveAllOnRemote() async {
        model.remote = remoteSnapshot(5)
        model.click(1)
        model.removeSelected()
        XCTAssertEqual(titles, ["Remote 0", "Remote 2", "Remote 3", "Remote 4"], "shown at once")
        await waitForRemoteEdits(1)
        guard case .remove(let removed) = remoteEdits.first else { return XCTFail("\(remoteEdits)") }
        XCTAssertEqual(removed.map(\.id), ["q1"])

        model.click(0)
        model.crop()
        await waitForRemoteEdits(2)
        guard case .remove(let cropped) = remoteEdits.last else { return XCTFail("\(remoteEdits)") }
        XCTAssertEqual(Set(cropped.map(\.id)), ["q2", "q3", "q4"])
        XCTAssertEqual(titles, ["Remote 0"])

        model.removeAll()
        await waitForRemoteEdits(3)
        XCTAssertEqual(remoteEdits.last, .clear)
        XCTAssertTrue(titles.isEmpty)
        XCTAssertEqual(refusedCount, 0)
    }

    func testSortReverseRandomizeOnLocal() {
        let tracks = makeTracks(5)
        player.restoreQueue([tracks[3], tracks[0], tracks[4], tracks[1], tracks[2]], currentIndex: nil, repeatMode: .off, isShuffled: false)
        model.sortByTitle()
        XCTAssertEqual(titles, ["Tone A", "Tone B", "Tone C", "Tone D", "Tone E"])
        model.reverse()
        XCTAssertEqual(titles, ["Tone E", "Tone D", "Tone C", "Tone B", "Tone A"])
        model.sortByFileName()
        XCTAssertEqual(titles, ["Tone A", "Tone B", "Tone C", "Tone D", "Tone E"])
        model.randomize()
        XCTAssertEqual(Set(titles), Set(tracks.map(\.title)), "randomize permutes, keeping every row")
        XCTAssertEqual(refusedCount, 0)
    }

    func testSortReverseRandomizeRefusedOnRemote() {
        model.remote = remoteSnapshot(3)
        let before = titles
        model.sortByTitle()
        model.sortByFileName()
        model.sortByPath()
        model.reverse()
        model.randomize()
        XCTAssertEqual(refusedCount, 5)
        XCTAssertEqual(titles, before)
        XCTAssertTrue(remoteEdits.isEmpty)
    }

    func testDragSelectedMovesRowsLocally() {
        loadLocal(5)
        model.click(1)
        model.dragSelected(by: 2)
        XCTAssertEqual(titles, ["Tone A", "Tone C", "Tone D", "Tone B", "Tone E"])
        model.dragSelected(by: -10)
        XCTAssertEqual(titles, ["Tone B", "Tone A", "Tone C", "Tone D", "Tone E"], "clamped at the top")
        XCTAssertTrue(remoteEdits.isEmpty)
    }

    func testDragSelectedOnRemoteSendsAMove() async {
        model.remote = remoteSnapshot(5)
        model.click(1)
        model.dragSelected(by: 2)
        await waitForRemoteEdits(1)
        XCTAssertEqual(remoteEdits, [.move(itemID: "q1", shift: 2)])
        model.click(0)
        model.commandClick(2)
        model.dragSelected(by: 1)
        XCTAssertEqual(notices, ["Drag one track at a time"])
    }

    // MARK: Scrolling and text

    func testScrollAndVisibleRange() {
        loadLocal(40)
        let visible = model.layout.visibleRows
        XCTAssertGreaterThan(visible, 0)
        XCTAssertLessThan(visible + 4, 40)
        XCTAssertFalse(model.allTracksAreVisible)
        XCTAssertEqual(model.visibleRange, 0..<visible)
        model.scroll(by: 4)
        XCTAssertEqual(model.visibleRange, 4..<(4 + visible))
        XCTAssertEqual(model.rows.first?.index, 4)
        XCTAssertEqual(model.rows.first?.position, 0)
        XCTAssertEqual(
            model.handleValue,
            PlaylistScroll.handleValue(position: model.scrollPosition, count: 40, visibleRows: visible))
        model.setScrollValue(1)
        XCTAssertEqual(model.visibleRange, (40 - visible)..<40)
        XCTAssertEqual(model.handleValue, 1)
        model.setScrollValue(-3)
        XCTAssertEqual(model.visibleRange, 0..<visible)
        XCTAssertEqual(model.handleValue, 0)

        player.clearQueue()
        player.restoreQueue(makeTracks(3), currentIndex: nil, repeatMode: .off, isShuffled: false)
        XCTAssertTrue(model.allTracksAreVisible)
    }

    func testShadeTextAndRunningTime() {
        XCTAssertNil(model.shadeTrackName)
        XCTAssertNil(model.shadeTrackDuration)
        loadLocal(3, current: 1)
        XCTAssertEqual(model.shadeTrackName, "2. Artist - Tone B")
        XCTAssertEqual(model.shadeTrackDuration, 62)
        // 61 + 62 + 63 = 186 s total; nothing selected.
        XCTAssertEqual(model.runningTimeText, PlaylistText.runningTime(selected: 0, total: 186))
        XCTAssertTrue(model.runningTimeText.hasPrefix("0:00/3:06"))
        model.click(0)
        model.commandClick(2)
        XCTAssertTrue(model.runningTimeText.hasPrefix("2:04/3:06"), model.runningTimeText)
    }

    func testHTMLEntriesMatchRows() {
        loadLocal(4)
        let entries = model.htmlEntries
        XCTAssertEqual(entries.map(\.name), model.rows.map(\.name))
        XCTAssertEqual(entries.map(\.duration), [61, 62, 63, 64])
    }
}

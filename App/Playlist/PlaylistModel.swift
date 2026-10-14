import AudioCore
import Foundation
import Observation
import SkinKit

/// The playlist window's state: a view of the local player's queue plus selection, scroll position and size. Owned by
/// `PlayerModel`. Edits go straight to `Player` (not through `TransportCommand`: that stream exists for transport
/// ordering, and the queue is only reachable locally). `MusicBackend` has no queue read API, so with a remote output
/// selected the list is empty.
@MainActor
@Observable
final class PlaylistModel {
    static let sizeKey = "playlistWindowSize"

    /// One visible row.
    struct Row: Identifiable, Equatable {
        let index: Int
        let id: UUID
        let number: String
        let name: String
        let duration: String
        let isCurrent: Bool
        let isSelected: Bool
        /// 0 for the first visible row.
        let position: Int
    }

    private let player: Player
    /// Whether the selected output is This Mac, the only output whose queue the window can show. Set by `PlayerModel`.
    @ObservationIgnored var isLocal: @MainActor () -> Bool = { true }

    var selection = PlaylistSelection()
    /// Webamp's 0...100 percent of the overflow.
    var scrollPosition: Double = 0
    /// The menu whose entries are showing.
    var openMenu: PlaylistLayout.Menu?
    var isDraggingScroll = false
    private(set) var steps: PlaylistLayout.Steps

    init(player: Player) {
        self.player = player
        if let saved = UserDefaults.standard.array(forKey: Self.sizeKey) as? [Int], saved.count == 2 {
            steps = PlaylistLayout.Steps(width: saved[0], height: saved[1])
        } else {
            steps = .zero
        }
    }

    // MARK: Layout

    var layout: PlaylistLayout { PlaylistLayout(steps: steps) }

    /// Resizing from the corner; persisted at once (the window keeps its top-left corner).
    func setSteps(_ new: PlaylistLayout.Steps) {
        guard new != steps else { return }
        steps = new
        UserDefaults.standard.set([new.width, new.height], forKey: Self.sizeKey)
    }

    // MARK: Queue

    var tracks: [Track] { isLocal() ? player.queue.tracks : [] }
    var currentIndex: Int? { isLocal() ? player.queue.currentIndex : nil }
    var count: Int { tracks.count }

    var visibleRange: Range<Int> {
        PlaylistScroll.visibleRange(position: scrollPosition, count: count, visibleRows: layout.visibleRows)
    }

    /// Only the rows in view, so a 10,000-track queue draws a dozen rows.
    var rows: [Row] {
        let tracks = tracks
        let range = visibleRange.clamped(to: tracks.indices)
        let current = currentIndex
        return range.map { index in
            let track = tracks[index]
            let fileName: String
            if case .file(let url) = track.source { fileName = url.lastPathComponent } else { fileName = "" }
            return Row(
                index: index, id: track.id,
                number: PlaylistText.rowNumber(index, count: tracks.count),
                name: PlaylistText.displayName(artist: track.artist, title: track.title, fileName: fileName),
                duration: PlaylistText.time(track.duration > 0 ? track.duration : nil),
                isCurrent: index == current, isSelected: selection.contains(track),
                position: index - range.lowerBound)
        }
    }

    /// The scroll handle's 0...1 value, snapped to rows.
    var handleValue: Double {
        PlaylistScroll.handleValue(position: scrollPosition, count: count, visibleRows: layout.visibleRows)
    }

    var allTracksAreVisible: Bool { count <= layout.visibleRows }

    /// "selected/total" (unknown durations count as 0), padded to 18 cells.
    var runningTimeText: String {
        let tracks = tracks
        let total = tracks.reduce(0) { $0 + max($1.duration, 0) }
        let selected = tracks.filter { selection.contains($0) }.reduce(0) { $0 + max($1.duration, 0) }
        return PlaylistText.runningTime(selected: selected, total: total)
    }

    // MARK: Scrolling

    func scroll(by rows: Int) {
        scrollPosition = PlaylistScroll.position(
            scrollingBy: rows, position: scrollPosition, count: count, visibleRows: layout.visibleRows)
    }

    /// `delta` is in skin pixels, positive scrolling toward later rows.
    func wheel(delta: CGFloat) {
        guard !allTracksAreVisible else { return }
        scrollPosition = PlaylistScroll.position(wheelDelta: delta, position: scrollPosition, count: count)
    }

    func setScrollValue(_ value: Double) {
        scrollPosition = min(max(value, 0), 1) * 100
    }

    // MARK: Selection and edits

    private var selectedIndices: Set<Int> { selection.indices(in: tracks) }

    /// Whether the row at `index` is selected (a plain press on one keeps the selection so it can be dragged).
    func isSelected(_ index: Int) -> Bool {
        let tracks = tracks
        return tracks.indices.contains(index) && selection.contains(tracks[index])
    }

    func click(_ index: Int) { selection.click(index, in: tracks) }
    func commandClick(_ index: Int) { selection.commandClick(index, in: tracks) }
    func shiftClick(_ index: Int) { selection.shiftClick(index, in: tracks) }
    func selectAll() { selection.selectAll(in: tracks) }
    func selectNone() { selection.selectNone() }
    func invertSelection() { selection.invert(in: tracks) }

    func playRow(_ index: Int) {
        guard isLocal() else { return }
        player.play(at: index)
    }

    /// Return plays the first selected row.
    func playFirstSelected() {
        if let first = selectedIndices.min() { playRow(first) }
    }

    func removeSelected() {
        guard isLocal() else { return }
        let indices = selectedIndices
        guard !indices.isEmpty else { return }
        player.removeTracks(at: IndexSet(indices))
        selection.prune(to: player.queue.tracks)
    }

    /// Keeps only the selected rows. With nothing selected it does nothing (Webamp would empty the list).
    func crop() {
        guard isLocal() else { return }
        let keep = selectedIndices
        guard !keep.isEmpty else { return }
        let drop = IndexSet(player.queue.tracks.indices.filter { !keep.contains($0) })
        player.removeTracks(at: drop)
        selection.prune(to: player.queue.tracks)
    }

    /// Webamp's removeAllTracks: stops and empties.
    func removeAll() {
        guard isLocal() else { return }
        player.clearQueue()
        selection.selectNone()
        scrollPosition = 0
    }

    /// Drags the selected rows `offset` rows (clamped at the ends by the queue).
    func dragSelected(by offset: Int) {
        guard isLocal(), offset != 0 else { return }
        player.moveTracks(selectedIndices, by: offset)
    }
}

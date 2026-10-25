import AudioCore
import Foundation
import LibraryBrowser
import SkinKit

/// Jump to File's state and actions (#0176), split out of `JumpToFilePanel` so they are unit tested (#0210). The panel
/// keeps the search field, the table and their delegates and forwards to this. The index is built and filtered off
/// the main actor, so a 50,000-row queue stays fast; `settle()` waits for both.
@MainActor
final class JumpToFileController {
    /// One listed match: the playlist row it plays and the text it shows.
    struct Result: Equatable {
        /// The row in the playlist editor (not the result's place in the list).
        let index: Int
        let name: String
    }

    let model: PlayerModel
    /// The search field's text; each change filters again.
    var query = "" {
        didSet { if query != oldValue { filter() } }
    }
    private(set) var results: [Result] = []
    /// The table's selected result rows (indices into `results`). Kept to valid rows by the panel.
    var selectedRows = IndexSet()
    /// The full queue the results index into.
    private(set) var shownTracks: [Track] = []
    /// Called after `results` change (the panel reloads its table and reselects).
    var onResultsChanged: () -> Void = {}
    /// Called after Play (the panel closes).
    var onClose: () -> Void = {}

    private var indexedTracks: [Track] = []
    private var index = JumpToFileIndex([])
    private var indexTask: Task<Void, Never>?
    private var filterTask: Task<Void, Never>?

    init(model: PlayerModel) {
        self.model = model
    }

    // MARK: Data

    /// Rebuilds the index from the playlist's rows, then filters.
    func rebuild() {
        let tracks = model.playlist.tracks
        let entries = tracks.map(Self.entry)
        indexTask?.cancel()
        indexTask = Task { [weak self] in
            let built = await Task.detached(priority: .userInitiated) { JumpToFileIndex(entries) }.value
            guard !Task.isCancelled, let self else { return }
            self.indexedTracks = tracks
            self.index = built
            self.filter()
        }
    }

    /// Waits for the index build and the filter running now.
    func settle() async {
        await indexTask?.value
        await filterTask?.value
    }

    func cancel() {
        indexTask?.cancel()
        filterTask?.cancel()
    }

    static func entry(_ track: Track) -> JumpToFileEntry {
        var fileName = ""
        if case .file(let url) = track.source, url.isFileURL { fileName = url.lastPathComponent }
        return JumpToFileEntry(artist: track.artist, title: track.title, album: track.album ?? "", fileName: fileName)
    }

    private func filter() {
        filterTask?.cancel()
        let query = self.query
        let index = self.index
        let tracks = indexedTracks
        filterTask = Task { [weak self] in
            let work = Task.detached(priority: .userInitiated) {
                index.matches(query, isCancelled: { Task.isCancelled })
            }
            let found = await withTaskCancellationHandler { await work.value } onCancel: { work.cancel() }
            guard let found, !Task.isCancelled, let self, self.query == query else { return }
            self.apply(found, tracks: tracks)
        }
    }

    /// Keeps the selected track selected when it is still listed, else selects the first result.
    private func apply(_ found: [Int], tracks: [Track]) {
        let selectedID = selectedRows.first.flatMap { row in
            results.indices.contains(row) ? shownTracks[results[row].index].id : nil
        }
        shownTracks = tracks
        results = found.map { Result(index: $0, name: PlaylistModel.displayName(tracks[$0])) }
        if found.isEmpty {
            selectedRows = []
        } else {
            selectedRows = [selectedID.flatMap { id in found.firstIndex { tracks[$0].id == id } } ?? 0]
        }
        onResultsChanged()
    }

    // MARK: State

    /// The first selected result, else the first result.
    var selectedResult: Result? {
        let row = selectedRows.first ?? 0
        return results.indices.contains(row) ? results[row] : nil
    }

    /// Queue works on any listed queue; on a Music Assistant queue it moves the rows after the current item (#0182).
    var canQueue: Bool { model.queueRowsSource != QueueRowsSource.none }

    /// The selected results' playlist rows in result (playlist) order, else the first result.
    var selectedIndices: [Int] {
        let rows = selectedRows.filter { results.indices.contains($0) }
        if rows.isEmpty { return results.first.map { [$0.index] } ?? [] }
        return rows.map { results[$0].index }
    }

    var isQueueEnabled: Bool { !results.isEmpty && canQueue }

    /// "Dequeue" when every selected result is already queued, like the playlist menu's `selectionIsQueued`.
    var queueButtonTitle: String {
        guard model.playlist.remote == nil else { return "Queue" }
        let queue = model.player.queue
        let indices = selectedIndices.filter { shownTracks.indices.contains($0) }
        let allQueued = !indices.isEmpty && indices.allSatisfy { queue.upNextPosition(of: shownTracks[$0].id) != nil }
        return allQueued ? "Dequeue" : "Queue"
    }

    /// The text under the table; nil when there are results.
    var emptyStateText: String? {
        if model.queueRowsSource == QueueRowsSource.none { return "This speaker\u{2019}s queue can\u{2019}t be listed" }
        if shownTracks.isEmpty { return "The playlist is empty. Add music from the Library (\u{2318}L) or File \u{203A} Open." }
        if results.isEmpty { return "No matches" }
        return nil
    }

    /// The play-next marker for a shown track (local queue only).
    func marker(for index: Int) -> String {
        guard model.playlist.remote == nil, shownTracks.indices.contains(index) else { return "" }
        return PlaylistText.queueMarker(model.player.queue.upNextPosition(of: shownTracks[index].id))
    }

    /// The result row an arrow or page key moves to from the selection, clamped at the ends; nil without results.
    func row(movingBy delta: Int) -> Int? {
        guard !results.isEmpty else { return nil }
        let current = selectedRows.first ?? (delta > 0 ? -1 : results.count)
        return min(max(current + delta, 0), results.count - 1)
    }

    // MARK: Actions

    /// Plays the first selected match, else the first match, through the playlist's own play path (local or remote),
    /// then closes. false when there is nothing to play.
    @discardableResult
    func playSelected() -> Bool {
        guard let result = selectedResult else { return false }
        model.playlist.playRow(result.index)
        model.playlist.reveal(result.index)
        onClose()
        return true
    }

    /// Toggles the selected results in the play-next list (like the playlist's Q). false when it can't.
    @discardableResult
    func toggleQueueSelected() -> Bool {
        let indices = selectedIndices
        guard canQueue, !indices.isEmpty else { return false }
        model.playlist.toggleQueue(indices)
        return true
    }
}

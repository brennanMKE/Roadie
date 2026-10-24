import AudioCore
import Foundation
import LibraryBrowser
import MusicBackendKit
import Observation
import SkinKit

/// The playlist window's state: a view of the local player's queue plus selection, scroll position and size. Owned by
/// `PlayerModel`. Edits go straight to `Player` (not through `TransportCommand`: that stream exists for transport
/// ordering). With a speaker selected, or This Mac fed by Music Assistant, it shows that backend's queue instead
/// (`remote`, set by `PlayerModel`, #0144): read-only apart from playing a row.
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
    /// Whether This Mac plays its local queue (not Music Assistant); only then is a row current. Set by `PlayerModel`.
    @ObservationIgnored var isPlayingLocalQueue: @MainActor () -> Bool = { true }
    /// Called before a row plays, so This Mac takes its local queue back from Music Assistant (#0114).
    @ObservationIgnored var onPlayLocal: @MainActor () -> Void = {}
    /// Plays the remote queue's row at this index (#0144). Set by `PlayerModel`.
    @ObservationIgnored var onPlayRemote: @MainActor (Int) -> Void = { _ in }
    /// An edit the remote queue can't take (sorting, #0145): shows the marquee notice. Set by `PlayerModel`.
    @ObservationIgnored var onRemoteRefused: @MainActor () -> Void = {}
    /// Sends a remove, move or clear to the remote queue (#0145). Set by `PlayerModel`.
    @ObservationIgnored var onEditRemote: @MainActor (QueueEdit) async throws -> Void = { _ in }
    /// A marquee notice about a remote edit: a refusal here, or the server's error (#0145). Set by `PlayerModel`.
    @ObservationIgnored var onRemoteNotice: @MainActor (String) -> Void = { _ in }
    /// Remote edits run one after another, in the order made (drag steps arrive quickly).
    @ObservationIgnored private var remoteEditChain: Task<Void, Never>?

    /// The remote queue the rows show; nil for the local queue. Set by `PlayerModel` (#0144).
    var remote: RemoteQueueSnapshot? {
        didSet { remoteTracks = remote.map(remoteTracks(for:)) ?? [] }
    }
    /// `remote`'s items as rows; ids stay the same per queue item so the selection survives refetches.
    private var remoteTracks: [Track] = []
    @ObservationIgnored private var remoteIDs: [String: UUID] = [:]

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

    var tracks: [Track] {
        if remote != nil { return remoteTracks }
        return isLocal() ? player.queue.tracks : []
    }

    var currentIndex: Int? {
        if let remote { return remote.currentIndex }
        return isLocal() && isPlayingLocalQueue() ? player.queue.currentIndex : nil
    }

    /// Whether the rows are a remote queue, which can't be sorted (#0144, #0145); refuses with the notice.
    private func refusesRemoteEdit() -> Bool {
        guard remote != nil else { return false }
        onRemoteRefused()
        return true
    }

    /// A `Track` per remote item, for the row, selection, HTML and File Info code the local queue uses.
    private func remoteTracks(for snapshot: RemoteQueueSnapshot) -> [Track] {
        var ids: [String: UUID] = [:]
        let tracks = snapshot.items.map { item in
            let id = remoteIDs[item.id] ?? UUID()
            ids[item.id] = id
            return Track(
                id: id, title: item.title, artist: item.artist ?? "",
                album: item.album, duration: item.duration ?? 0,
                source: .file(item.item.flatMap { URL(string: $0.rawValue) } ?? URL(string: "about:blank")!))
        }
        remoteIDs = ids
        selection.prune(to: tracks)
        return tracks
    }
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
            return Row(
                index: index, id: track.id,
                number: PlaylistText.rowNumber(index, count: tracks.count),
                name: Self.displayName(track),
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

    /// The current track as the shade strip shows it, `"<n>. <name>"` (Webamp `getMinimalMediaText`); nil without one.
    var shadeTrackName: String? {
        let tracks = tracks
        guard let index = currentIndex, tracks.indices.contains(index) else { return nil }
        return "\(index + 1). " + Self.displayName(tracks[index])
    }

    /// The row text: "artist - title", else the title, else the file name.
    static func displayName(_ track: Track) -> String {
        let fileName: String
        if case .file(let url) = track.source { fileName = url.lastPathComponent } else { fileName = "" }
        return PlaylistText.displayName(artist: track.artist, title: track.title, fileName: fileName)
    }

    /// The current track's length for the shade strip; nil without a track or a known length.
    var shadeTrackDuration: TimeInterval? {
        guard let index = currentIndex, tracks.indices.contains(index) else { return nil }
        let duration = tracks[index].duration
        return duration > 0 ? duration : nil
    }

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

    /// Selects row `index` alone and scrolls it into view (Jump to File, #0176).
    func reveal(_ index: Int) {
        let tracks = tracks
        guard tracks.indices.contains(index) else { return }
        selection.click(index, in: tracks)
        scrollPosition = PlaylistScroll.position(revealing: index, position: scrollPosition, count: tracks.count,
                                                 visibleRows: layout.visibleRows)
    }

    func commandClick(_ index: Int) { selection.commandClick(index, in: tracks) }
    func shiftClick(_ index: Int) { selection.shiftClick(index, in: tracks) }
    func selectAll() { selection.selectAll(in: tracks) }
    func selectNone() { selection.selectNone() }
    func invertSelection() { selection.invert(in: tracks) }

    func playRow(_ index: Int) {
        if let remote {
            if remote.items.indices.contains(index) { onPlayRemote(remote.items[index].index) }
            return
        }
        guard isLocal() else { return }
        onPlayLocal()
        player.play(at: index)
    }

    /// Return plays the first selected row.
    func playFirstSelected() {
        if let first = selectedIndices.min() { playRow(first) }
    }

    func removeSelected() {
        if let remote {
            removeRemote(QueueEditPlan.remove(selected: Set(selectedIndices), in: remote))
            return
        }
        guard isLocal() else { return }
        let indices = selectedIndices
        guard !indices.isEmpty else { return }
        player.removeTracks(at: IndexSet(indices))
        selection.prune(to: player.queue.tracks)
    }

    /// Keeps only the selected rows. With nothing selected it does nothing (Webamp would empty the list).
    func crop() {
        if let remote {
            removeRemote(QueueEditPlan.crop(selected: Set(selectedIndices), in: remote))
            return
        }
        guard isLocal() else { return }
        let keep = selectedIndices
        guard !keep.isEmpty else { return }
        let drop = IndexSet(player.queue.tracks.indices.filter { !keep.contains($0) })
        player.removeTracks(at: drop)
        selection.prune(to: player.queue.tracks)
    }

    /// Webamp's removeAllTracks: stops and empties.
    func removeAll() {
        if let remote {
            guard !remote.items.isEmpty else { return }
            sendRemote(.clear)
            selection.selectNone()
            scrollPosition = 0
            return
        }
        guard isLocal() else { return }
        player.clearQueue()
        selection.selectNone()
        scrollPosition = 0
    }

    /// Drags the selected rows `offset` rows (clamped at the ends by the queue).
    func dragSelected(by offset: Int) {
        guard offset != 0 else { return }
        if let remote {
            switch QueueEditPlan.move(selected: Set(selectedIndices), by: offset, in: remote) {
            case .none: break
            case .refusedMultiple: onRemoteNotice("Drag one track at a time")
            case .move(let itemID, let shift): sendRemote(.move(itemID: itemID, shift: shift))
            }
            return
        }
        guard isLocal() else { return }
        player.moveTracks(selectedIndices, by: offset)
    }

    // MARK: Remote queue edits (#0145)

    private func removeRemote(_ removal: QueueEditPlan.Removal) {
        if removal.skippedCurrent { onRemoteNotice("Can't remove the playing track") }
        guard !removal.items.isEmpty else { return }
        sendRemote(.remove(items: removal.items))
    }

    /// Shows the edit at once and sends it after any earlier one; a refusal puts the rows back as they were. The
    /// queue watcher's refetch then confirms the server's order.
    private func sendRemote(_ edit: QueueEdit) {
        guard let before = remote else { return }
        remote = QueueEditPlan.apply(edit, to: before)
        let previous = remoteEditChain
        remoteEditChain = Task { [weak self] in
            await previous?.value
            guard let self else { return }
            do {
                try await self.onEditRemote(edit)
            } catch is CancellationError {
            } catch {
                if self.remote?.output == before.output { self.remote = before }
                self.onRemoteNotice((error as? LocalizedError)?.errorDescription ?? "Music Assistant refused")
            }
        }
    }

    // MARK: Sort List (MISC menu)

    /// Sorts by the row text, so the order matches what the list shows.
    func sortByTitle() {
        if refusesRemoteEdit() { return }
        guard isLocal() else { return }
        player.sortQueue(by: Self.displayName)
    }

    func sortByFileName() {
        if refusesRemoteEdit() { return }
        guard isLocal() else { return }
        player.sortQueue(by: PlaylistSortKey.fileName)
    }

    func sortByPath() {
        if refusesRemoteEdit() { return }
        guard isLocal() else { return }
        player.sortQueue(by: PlaylistSortKey.path)
    }

    func reverse() {
        if refusesRemoteEdit() { return }
        guard isLocal() else { return }
        player.reverseQueue()
    }

    /// Winamp's Randomize List: permutes the list itself (shuffle mode only changes play order).
    func randomize() {
        if refusesRemoteEdit() { return }
        guard isLocal() else { return }
        player.randomizeQueue()
    }

    // MARK: File Info and HTML playlist

    /// The first selected row, else the current track, else nil.
    var fileInfoTrack: Track? {
        let tracks = tracks
        if let first = selectedIndices.min(), tracks.indices.contains(first) { return tracks[first] }
        guard let current = currentIndex, tracks.indices.contains(current) else { return nil }
        return tracks[current]
    }

    var htmlEntries: [PlaylistHTML.Entry] {
        tracks.map { PlaylistHTML.Entry(name: Self.displayName($0), duration: $0.duration > 0 ? $0.duration : nil) }
    }
}

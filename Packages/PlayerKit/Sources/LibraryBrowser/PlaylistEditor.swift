import Foundation
import MusicBackendKit
import Observation
import os

/// The open playlist's structural edits (#0138, design §3.4–3.5): remove and reorder. Every edit changes `rows`
/// at once, then sends; a refusal puts the rows back and sets `error` (the bar offers Retry). Edits run one at a
/// time through one task chain, and a generation counter drops a refetch that an edit made stale.
@MainActor @Observable
public final class PlaylistEditor {
    public enum PendingEdit: Hashable, Sendable {
        case removing(Int)
        case moving

        /// The bar's text while the edit is in flight.
        public var text: String {
            switch self {
            case .removing(let count): count == 1 ? "Removing 1 track\u{2026}" : "Removing \(count) tracks\u{2026}"
            case .moving: "Moving\u{2026}"
            }
        }
    }

    public let backend: any MusicBackend
    /// The playlist whose rows these are; nil when none is open.
    public private(set) var playlist: LibraryPlaylist?
    public private(set) var rows: [LibraryTrack] = []
    /// The edit in flight; structural edits are refused while it is set.
    public private(set) var pending: PendingEdit?
    /// The last refusal, for the bar.
    public private(set) var error: String?
    /// Set when the server answered a move with "unsupported": reorder stays off for the session.
    public private(set) var reorderRefused = false

    /// Called whenever `rows` changes, so the browser's track list follows.
    @ObservationIgnored public var onRows: (@MainActor ([LibraryTrack]) -> Void)?
    /// How long to wait for the server's `playlistUpdated` before refetching anyway.
    @ObservationIgnored public var refetchFallback: Duration
    @ObservationIgnored private var queue: Task<Void, Never>?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var refetchTask: Task<Void, Never>?
    /// The delayed refetch after an own write; the server's change event replaces it.
    @ObservationIgnored private var fallbackTask: Task<Void, Never>?
    @ObservationIgnored private var retryEdit: (@MainActor () -> Void)?
    private static let log = Logger(subsystem: "co.sstools.roadie", category: "PlaylistEditor")

    public init(backend: any MusicBackend, refetchFallback: Duration = .seconds(2)) {
        self.backend = backend
        self.refetchFallback = refetchFallback
    }

    // MARK: Open playlist

    /// The browser loaded `rows` for `playlist`.
    public func open(_ playlist: LibraryPlaylist, rows: [LibraryTrack]) {
        if self.playlist?.id != playlist.id {
            pending = nil
            error = nil
            retryEdit = nil
            reorderRefused = false
        }
        self.playlist = playlist
        generation += 1
        self.rows = rows
    }

    public func close() {
        playlist = nil
        rows = []
        pending = nil
        error = nil
        retryEdit = nil
        generation += 1
        refetchTask?.cancel()
        refetchTask = nil
        fallbackTask?.cancel()
        fallbackTask = nil
    }

    public func isOpen(_ id: MediaID) -> Bool { playlist?.id == id }

    // MARK: What's allowed

    public var canRemove: Bool {
        guard let playlist, pending == nil else { return false }
        return backend.capabilities.contains(.playlistEditing) && playlist.editing.contains(.addRemove)
    }

    public var canReorder: Bool {
        guard let playlist, pending == nil, !reorderRefused else { return false }
        return backend.capabilities.contains(.playlistEditing) && playlist.editing.contains(.reorder)
    }

    /// Editable tracks, but the server has no reorder command: the one-shot caption says why.
    public var reorderNeedsNewerServer: Bool {
        guard let playlist else { return false }
        return backend.capabilities.contains(.playlistEditing) && playlist.editing.contains(.addRemove)
            && (!playlist.editing.contains(.reorder) || reorderRefused)
    }

    public func dismissError() {
        error = nil
        retryEdit = nil
    }

    /// Runs the refused edit again.
    public func retry() {
        let edit = retryEdit
        error = nil
        retryEdit = nil
        edit?()
    }

    // MARK: Edits

    /// Removes the selected rows at once and sends their 1-based positions. Returns the queued work (tests await
    /// it), nil when refused.
    @discardableResult
    public func remove(selected: Set<MediaID>) -> Task<Void, Never>? {
        guard canRemove, let playlist else { return nil }
        let positions = PlaylistPositions.positions(of: selected, in: rows)
        guard !positions.isEmpty else { return nil }
        let snapshot = rows
        let id = playlist.id
        error = nil
        pending = .removing(positions.count)
        setRows(PlaylistPositions.renumber(rows, afterRemoving: positions))
        generation += 1
        return enqueue { [weak self] in
            guard let self else { return }
            do {
                try await backend.remove(positions: positions, fromPlaylist: id)
                Self.log.info("removed \(positions.count, privacy: .public) track(s) from a playlist")
                finish(id)
                scheduleRefetch(id, after: refetchFallback)
            } catch {
                fail(error, restoring: snapshot, id: id) { [weak self] in _ = self?.remove(selected: selected) }
            }
        }
    }

    /// SwiftUI's `onMove`: one row at a time (Music Assistant moves one track per command).
    @discardableResult
    public func move(from source: IndexSet, to destination: Int) -> Task<Void, Never>? {
        guard source.count == 1, let index = source.first, rows.indices.contains(index) else { return nil }
        return move(index, toFinal: PlaylistPositions.finalIndex(from: index, onMoveDestination: destination))
    }

    @discardableResult
    public func moveUp(_ id: MediaID) -> Task<Void, Never>? {
        guard let index = rows.firstIndex(where: { $0.id == id }), index > 0 else { return nil }
        return move(index, toFinal: index - 1)
    }

    @discardableResult
    public func moveDown(_ id: MediaID) -> Task<Void, Never>? {
        guard let index = rows.firstIndex(where: { $0.id == id }), index < rows.count - 1 else { return nil }
        return move(index, toFinal: index + 1)
    }

    private func move(_ index: Int, toFinal target: Int) -> Task<Void, Never>? {
        guard canReorder, let playlist, rows.indices.contains(index), rows.indices.contains(target), index != target
        else { return nil }
        let from = PlaylistPositions.position(of: index, in: rows)
        let to = PlaylistPositions.position(of: target, in: rows)
        let snapshot = rows
        let id = playlist.id
        error = nil
        pending = .moving
        setRows(PlaylistPositions.moving(rows, from: index, to: target))
        generation += 1
        return enqueue { [weak self] in
            guard let self else { return }
            do {
                try await backend.movePlaylistTrack(id, from: from, to: to)
                finish(id)
                // The move is synchronous server-side: the new order is there now.
                scheduleRefetch(id, after: .zero)
            } catch {
                if case .unsupported? = error as? MusicBackendError { reorderRefused = true }
                fail(error, restoring: snapshot, id: id) { [weak self] in
                    let movedID = snapshot[index].id
                    guard let self, let current = rows.firstIndex(where: { $0.id == movedID }) else { return }
                    _ = move(current, toFinal: target)
                }
            }
        }
    }

    // MARK: Refetch

    /// The server says the playlist changed (or the fallback fired): refetch unless an edit made it stale.
    public func reloadIfOpen(_ id: MediaID) {
        guard isOpen(id) else { return }
        fallbackTask?.cancel()
        fallbackTask = nil
        refetchTask?.cancel()
        refetchTask = Task { [weak self] in await self?.refetch(id) }
    }

    private func scheduleRefetch(_ id: MediaID, after delay: Duration) {
        fallbackTask?.cancel()
        fallbackTask = Task { [weak self] in
            if delay > .zero {
                try? await Task.sleep(for: delay)
                guard !Task.isCancelled else { return }
            }
            await self?.refetch(id)
        }
    }

    private func refetch(_ id: MediaID) async {
        let started = generation
        do {
            let fresh = try await backend.tracks(ofPlaylist: id)
            guard !Task.isCancelled, isOpen(id), started == generation, pending == nil else { return }
            setRows(fresh)
        } catch {
            Self.log.info("playlist refetch failed")
        }
    }

    // MARK: Helpers

    private func enqueue(_ work: @escaping @MainActor () async -> Void) -> Task<Void, Never> {
        let previous = queue
        let task = Task { @MainActor in
            await previous?.value
            await work()
        }
        queue = task
        return task
    }

    private func finish(_ id: MediaID) {
        guard isOpen(id) else { return }
        pending = nil
    }

    private func fail(_ error: any Error, restoring snapshot: [LibraryTrack], id: MediaID, retry: @escaping @MainActor () -> Void) {
        Self.log.info("playlist edit failed")
        guard isOpen(id) else { return }
        pending = nil
        generation += 1
        setRows(snapshot)
        self.error = userMessage(for: error)
        retryEdit = retry
    }

    private func setRows(_ new: [LibraryTrack]) {
        rows = new
        onRows?(new)
    }
}

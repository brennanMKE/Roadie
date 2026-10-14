import Foundation

/// The playlist window's selected rows, tracked by `Track.id` so the selection survives reorders and removals.
/// `anchor` is Webamp's `lastSelectedIndex`, the row a shift-click extends from. Rules are Webamp's reducers/playlist.ts.
public struct PlaylistSelection: Sendable, Equatable {
    public private(set) var ids: Set<UUID> = []
    public private(set) var anchor: Int?

    public init() {}

    /// CLICKED_TRACK: only that row.
    public mutating func click(_ index: Int, in tracks: [Track]) {
        guard tracks.indices.contains(index) else { return }
        ids = [tracks[index].id]
        anchor = index
    }

    /// CTRL_CLICKED_TRACK: toggles the row; the anchor moves there even when it was unselected.
    public mutating func commandClick(_ index: Int, in tracks: [Track]) {
        guard tracks.indices.contains(index) else { return }
        let id = tracks[index].id
        if ids.contains(id) { ids.remove(id) } else { ids.insert(id) }
        anchor = index
    }

    /// SHIFT_CLICKED_TRACK: the range from the anchor to `index`; no anchor changes nothing. The anchor stays.
    public mutating func shiftClick(_ index: Int, in tracks: [Track]) {
        guard let anchor, tracks.indices.contains(index), tracks.indices.contains(anchor) else { return }
        ids = Set(tracks[min(anchor, index)...max(anchor, index)].map(\.id))
    }

    public mutating func selectAll(in tracks: [Track]) { ids = Set(tracks.map(\.id)) }
    public mutating func selectNone() { ids = [] }
    public mutating func invert(in tracks: [Track]) { ids = Set(tracks.map(\.id)).subtracting(ids) }

    /// Drops ids that are no longer queued. Webamp's REMOVE_TRACKS also clears the anchor.
    public mutating func prune(to tracks: [Track]) {
        let queued = Set(tracks.map(\.id))
        let kept = ids.intersection(queued)
        if kept != ids { anchor = nil }
        ids = kept
        if let anchor, !tracks.indices.contains(anchor) { self.anchor = nil }
    }

    public func indices(in tracks: [Track]) -> Set<Int> {
        Set(tracks.indices.filter { ids.contains(tracks[$0].id) })
    }

    public func contains(_ track: Track) -> Bool { ids.contains(track.id) }
}

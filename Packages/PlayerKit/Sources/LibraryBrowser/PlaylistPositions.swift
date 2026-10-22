import Foundation
import MusicBackendKit

/// 1-based playlist positions (#0138): which positions a selection is, and the rows after a local edit.
public enum PlaylistPositions {
    /// A row's position: its `playlistPosition`, or its index + 1 when the backend gave none.
    public static func position(of index: Int, in rows: [LibraryTrack]) -> Int {
        rows[index].playlistPosition ?? index + 1
    }

    /// The positions of the selected rows, highest first, so lower ones don't shift underneath.
    public static func positions(of selected: Set<MediaID>, in rows: [LibraryTrack]) -> [Int] {
        rows.indices.filter { selected.contains(rows[$0].id) }.map { position(of: $0, in: rows) }.sorted(by: >)
    }

    /// `rows` without the tracks at `positions`, renumbered 1..., so a later edit before the refetch is still right.
    public static func renumber(_ rows: [LibraryTrack], afterRemoving positions: [Int]) -> [LibraryTrack] {
        let removed = Set(positions)
        return renumbered(rows.indices.filter { !removed.contains(position(of: $0, in: rows)) }.map { rows[$0] })
    }

    /// `rows` with the row at `source` moved to the final index `destination`, renumbered.
    public static func moving(_ rows: [LibraryTrack], from source: Int, to destination: Int) -> [LibraryTrack] {
        var moved = rows
        let row = moved.remove(at: source)
        moved.insert(row, at: min(max(destination, 0), moved.count))
        return renumbered(moved)
    }

    /// SwiftUI's `onMove` destination (an index before the move) as the row's final index.
    public static func finalIndex(from source: Int, onMoveDestination destination: Int) -> Int {
        destination > source ? destination - 1 : destination
    }

    public static func renumbered(_ rows: [LibraryTrack]) -> [LibraryTrack] {
        rows.enumerated().map { index, row in
            var row = row
            row.playlistPosition = index + 1
            return row
        }
    }
}

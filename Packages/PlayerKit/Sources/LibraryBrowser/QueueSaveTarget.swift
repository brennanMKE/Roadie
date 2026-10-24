import Foundation
import MusicBackendKit

/// Where Playback › Save Queue as Playlist… writes the shown queue (#0140, #0132 decision 4): the local queue keeps the
/// file panel; a queue Music Assistant plays becomes a server playlist.
public enum QueueSaveTarget: Hashable, Sendable {
    /// AudioCore's queue: an M3U8/M3U/PLS file.
    case file
    /// The backend's queue on this output: `saveQueueAsPlaylist(on:named:)`.
    case remote(OutputDevice.ID)
    /// A speaker of a backend that can't save its queue.
    case refused

    /// Follows `QueueRowsSelection`: the queue the playlist editor shows is the queue that gets saved.
    public static func choose(
        output: OutputDevice.ID, feed: ThisMacFeed, capabilities: BackendCapabilities
    ) -> QueueSaveTarget {
        switch QueueRowsSelection.choose(output: output, feed: feed, remoteCapabilities: capabilities) {
        case .local: .file
        case .remote(let target): .remote(target)
        case .none: .refused
        }
    }

    /// The playlist editor's LIST › Load (#0146) follows the same choice: the local queue loads a playlist file; a queue
    /// Music Assistant plays loads one of its playlists, replacing that queue.
    public static func load(
        output: OutputDevice.ID, feed: ThisMacFeed, capabilities: BackendCapabilities
    ) -> QueueSaveTarget {
        choose(output: output, feed: feed, capabilities: capabilities)
    }

    /// What LIST › Load offers (#0190). A Music Assistant queue: its playlists. The local queue: a playlist file,
    /// plus the Library's playlists when the Library's source has them (loading one moves This Mac onto that source).
    public enum LoadChoice: Hashable, Sendable { case libraryPlaylist, file }

    public static func loadChoices(
        output: OutputDevice.ID, feed: ThisMacFeed, capabilities: BackendCapabilities, libraryHasPlaylists: Bool
    ) -> [LoadChoice] {
        switch load(output: output, feed: feed, capabilities: capabilities) {
        case .remote: [.libraryPlaylist]
        case .file: libraryHasPlaylists ? [.libraryPlaylist, .file] : [.file]
        case .refused: []
        }
    }
}

import Foundation

extension BackendCapabilities {
    /// Shows (and later edits, #0145) the queue of a remote output in the playlist editor (#0144).
    public static let queueEditing = BackendCapabilities(rawValue: 1 << 9)
}

/// One row of a backend-owned queue (#0144). Named apart from LocalPlayback's `QueueSnapshot`, the saved local queue.
public struct RemoteQueueItem: Identifiable, Hashable, Sendable {
    /// The backend's queue item id (Music Assistant's `queue_item_id`): stable across refetches.
    public var id: String
    /// 0-based position in the queue.
    public var index: Int
    public var title: String
    public var artist: String?
    public var album: String?
    public var duration: TimeInterval?
    /// The media item it plays, when the backend says.
    public var item: MediaID?
    public var isAvailable: Bool

    public init(
        id: String, index: Int, title: String, artist: String? = nil, album: String? = nil,
        duration: TimeInterval? = nil, item: MediaID? = nil, isAvailable: Bool = true
    ) {
        self.id = id
        self.index = index
        self.title = title
        self.artist = artist
        self.album = album
        self.duration = duration
        self.item = item
        self.isAvailable = isAvailable
    }
}

/// A remote output's queue as last fetched. `items` stops at the backend's cap (2,000 for Music Assistant, #0132
/// decision 10); `total` is the server's count.
public struct RemoteQueueSnapshot: Hashable, Sendable {
    public var output: OutputDevice.ID
    public var items: [RemoteQueueItem]
    public var currentIndex: Int?
    public var total: Int
    /// False while later pages are still loading.
    public var isComplete: Bool

    public init(
        output: OutputDevice.ID, items: [RemoteQueueItem] = [], currentIndex: Int? = nil, total: Int? = nil,
        isComplete: Bool = true
    ) {
        self.output = output
        self.items = items
        self.currentIndex = currentIndex
        self.total = total ?? items.count
        self.isComplete = isComplete
    }

    public static func empty(on output: OutputDevice.ID) -> RemoteQueueSnapshot { RemoteQueueSnapshot(output: output) }
}

/// A change to a remote queue (#0144, #0145).
public enum QueueEdit: Hashable, Sendable {
    /// Plays the row at this 0-based index.
    case play(index: Int)
    /// Removes these items, one request each, highest index first so the lower indices stay put.
    case remove(items: [RemoteQueueItem])
    /// Moves one item `shift` rows (positive: down, toward the end).
    case move(itemID: String, shift: Int)
    /// Empties the queue.
    case clear
}

/// Why a remote queue refused an edit (#0145).
public enum QueueEditError: Error, Hashable, Sendable, LocalizedError {
    /// The server won't move or delete an item at or before its buffered index (Music Assistant's `IndexError`).
    case buffered

    public var errorDescription: String? {
        switch self {
        case .buffered: "Track already buffered"
        }
    }
}

extension MusicBackend {
    public func queue(on output: OutputDevice.ID) async -> AsyncStream<RemoteQueueSnapshot> {
        let (stream, continuation) = AsyncStream<RemoteQueueSnapshot>.makeStream()
        continuation.yield(.empty(on: output))
        continuation.finish()
        return stream
    }

    public func edit(_ edit: QueueEdit, on output: OutputDevice.ID) async throws {
        throw MusicBackendError.unsupported(.queueEditing)
    }
}

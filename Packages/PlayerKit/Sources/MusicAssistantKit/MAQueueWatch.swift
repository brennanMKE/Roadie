import Foundation
import MusicBackendKit
import os

/// How a queue watcher pages and refreshes (#0144).
public struct MAQueuePolicy: Hashable, Sendable {
    /// `player_queues/items` page size.
    public var pageSize: Int
    /// Items kept at most (#0132 decision 10); the snapshot's `total` still says how many the server has.
    public var cap: Int
    /// A burst of queue events costs one refetch.
    public var refetchDebounce: Duration
    /// Safety net while queue events stay unverified (#0076).
    public var poll: Duration

    public init(
        pageSize: Int = 500, cap: Int = 2000, refetchDebounce: Duration = .milliseconds(150), poll: Duration = .seconds(30)
    ) {
        self.pageSize = pageSize
        self.cap = cap
        self.refetchDebounce = refetchDebounce
        self.poll = poll
    }

    public static let standard = MAQueuePolicy()
}

/// One subscriber's view of one output's queue: `player_queues/get` plus paged `player_queues/items`, refetched on
/// `queue_items_updated`/`queue_updated` for that queue, on a slow poll and after a reconnect, until cancelled.
actor MAQueueWatch {
    private let client: MusicAssistantClient
    private let output: OutputDevice.ID
    private let clock: any Clock<Duration>
    private let policy: MAQueuePolicy
    /// The queue playing on the output now (a synced speaker plays its leader's); asked on every refetch.
    private let resolveQueueID: @Sendable () async throws -> String
    private let yield: @Sendable (RemoteQueueSnapshot) -> Void
    private let log = Logger(subsystem: "co.sstools.roadie", category: "MusicAssistantBackend")

    private var queueID: String?
    private var generation = 0
    private var refetchTask: Task<Void, Never>?
    private var last: RemoteQueueSnapshot?

    init(
        client: MusicAssistantClient, output: OutputDevice.ID, clock: any Clock<Duration>, policy: MAQueuePolicy,
        resolveQueueID: @escaping @Sendable () async throws -> String,
        yield: @escaping @Sendable (RemoteQueueSnapshot) -> Void
    ) {
        self.client = client
        self.output = output
        self.clock = clock
        self.policy = policy
        self.resolveQueueID = resolveQueueID
        self.yield = yield
    }

    func run() async {
        let events = await client.events()
        let states = await client.states()
        await refetch()
        await withTaskGroup(of: Void.self) { group in
            group.addTask { for await event in events { await self.handle(event) } }
            group.addTask { await self.pollLoop() }
            group.addTask {
                var lost = false
                for await state in states {
                    switch state {
                    case .reconnecting: lost = true
                    case .connected where lost:
                        lost = false
                        await self.refetch()
                    default: break
                    }
                }
            }
            await group.waitForAll()
        }
        refetchTask?.cancel()
        refetchTask = nil
    }

    /// Whether `event` is a queue change of `queueID` (by `object_id`, else `data.queue_id`).
    static func isChange(_ event: MAServerEvent, of queueID: String?) -> Bool {
        guard let queueID, event.event == "queue_items_updated" || event.event == "queue_updated" else { return false }
        let target = event.objectID ?? event.data["queue_id"]?.stringValue
        return target == queueID
    }

    private func handle(_ event: MAServerEvent) {
        guard !Task.isCancelled, Self.isChange(event, of: queueID) else { return }
        scheduleRefetch()
    }

    private func scheduleRefetch() {
        guard refetchTask == nil else { return }
        let clock = clock
        let delay = policy.refetchDebounce
        refetchTask = Task {
            do { try await clock.sleep(for: delay) } catch { return }
            await self.debouncedRefetch()
        }
    }

    private func debouncedRefetch() async {
        refetchTask = nil
        guard !Task.isCancelled else { return }
        await refetch()
    }

    private func pollLoop() async {
        while !Task.isCancelled {
            do { try await clock.sleep(for: policy.poll) } catch { return }
            await refetch()
        }
    }

    /// The queue, then its items page by page: the first page is shown at once, later ones as they arrive. A newer
    /// refetch abandons an older one's paging. Failures keep the last snapshot.
    private func refetch() async {
        guard !Task.isCancelled else { return }
        generation += 1
        let mine = generation
        do {
            let id = try await resolveQueueID()
            guard mine == generation else { return }
            queueID = id
            let queueJSON = try await client.call(.queue(id: id))
            guard mine == generation, !Task.isCancelled else { return }
            guard !queueJSON.isNull, let queue = try? queueJSON.decode(as: MAPlayerQueue.self) else {
                emit(.empty(on: output))
                return
            }
            let total = queue.items ?? 0
            let wanted = min(total, policy.cap)
            var items: [RemoteQueueItem] = []
            while items.count < wanted {
                let limit = min(policy.pageSize, wanted - items.count)
                let page = try await client.call(.queueItems(id: id, limit: limit, offset: items.count))
                    .decode(as: [MAQueueItem].self)
                guard mine == generation, !Task.isCancelled else { return }
                let offset = items.count
                items += page.enumerated().map { Self.item($0.element, fallbackIndex: offset + $0.offset) }
                let done = page.isEmpty || items.count >= wanted
                emit(
                    RemoteQueueSnapshot(
                        output: output, items: items, currentIndex: queue.currentIndex, total: total, isComplete: done))
                if page.isEmpty { return }
            }
            if wanted == 0 {
                emit(RemoteQueueSnapshot(output: output, currentIndex: queue.currentIndex, total: total))
            }
        } catch {
            log.debug("queue refetch failed: \(String(describing: type(of: error)), privacy: .public)")
        }
    }

    private func emit(_ snapshot: RemoteQueueSnapshot) {
        guard !Task.isCancelled, snapshot != last else { return }
        last = snapshot
        yield(snapshot)
    }

    /// The row for one `player_queues/items` entry: title, artist and album from its track when it decodes.
    static func item(_ item: MAQueueItem, fallbackIndex: Int) -> RemoteQueueItem {
        let track = item.track
        let artist = track?.artists?.first.map(\.name).flatMap { $0.isEmpty ? nil : $0 }
        let title = track?.name ?? item.name ?? ""
        return RemoteQueueItem(
            id: item.queueItemID, index: item.index ?? fallbackIndex,
            title: artist == nil ? (item.name ?? title) : title,
            artist: artist, album: track?.album?.name,
            duration: item.duration ?? track?.duration,
            item: track.map { MediaID(.track, $0.uri) },
            isAvailable: item.available ?? true)
    }
}

extension MARequest {
    /// Plays the queue's item at the 0-based `index` (#0144).
    public static func queuePlayIndex(queueID: String, index: Int) -> MARequest {
        MARequest(
            command: "player_queues/play_index", args: ["queue_id": .string(queueID), "index": .number(Double(index))])
    }
}

extension MAQueueItem {
    /// `media_item` as a track, leniently: nil when absent or another shape (a radio stream, a podcast episode).
    public var track: MATrack? { mediaItem.flatMap { try? $0.decode(as: MATrack.self) } }
}

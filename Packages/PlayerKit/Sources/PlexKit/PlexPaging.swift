import Foundation

public struct PlexPageRequest: Hashable, Sendable {
    public var start: Int
    public var size: Int

    public init(start: Int = 0, size: Int = 100) {
        self.start = start
        self.size = size
    }

    public static let first = PlexPageRequest()
}

public struct PlexPage<Item: Hashable & Sendable>: Hashable, Sendable {
    public var items: [Item]
    public var offset: Int
    public var size: Int
    public var totalSize: Int

    public init(items: [Item], offset: Int, size: Int, totalSize: Int) {
        self.items = items
        self.offset = offset
        self.size = size
        self.totalSize = totalSize
    }

    public var hasMore: Bool { offset + items.count < totalSize }

    public var next: PlexPageRequest? {
        hasMore ? PlexPageRequest(start: offset + items.count, size: max(size, 1)) : nil
    }
}

extension PlexClient {
    /// Walks pages until `hasMore` is false. `limit` caps the total so a server that keeps
    /// answering cannot run the loop forever; an empty page also stops it.
    public func allItems<Item: Hashable & Sendable>(
        pageSize: Int = 200,
        limit: Int = 10_000,
        _ fetch: (PlexPageRequest) async throws -> PlexPage<Item>
    ) async throws -> [Item] {
        var result: [Item] = []
        var request: PlexPageRequest? = PlexPageRequest(start: 0, size: pageSize)
        while let current = request, result.count < limit {
            let page = try await fetch(current)
            result.append(contentsOf: page.items)
            if page.items.isEmpty { break }
            request = page.next.map { PlexPageRequest(start: $0.start, size: pageSize) }
        }
        return Array(result.prefix(limit))
    }
}

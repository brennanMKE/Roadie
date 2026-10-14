import Foundation

public struct PageRequest: Hashable, Sendable {
    public var offset: Int
    public var limit: Int

    public init(offset: Int = 0, limit: Int = 100) {
        self.offset = offset
        self.limit = limit
    }

    public static let first = PageRequest()
}

public struct Page<Item: Hashable & Sendable>: Hashable, Sendable {
    public var items: [Item]
    public var offset: Int
    /// nil when the backend does not report one.
    public var total: Int?
    /// Set by the backend; nil means this is the last page.
    public var nextOffset: Int?

    public init(items: [Item], offset: Int, total: Int?, nextOffset: Int?) {
        self.items = items
        self.offset = offset
        self.total = total
        self.nextOffset = nextOffset
    }

    public var hasMore: Bool { nextOffset != nil }

    public func next(limit: Int) -> PageRequest? {
        nextOffset.map { PageRequest(offset: $0, limit: limit) }
    }

    /// Convenience for backends: `nextOffset` from `total` when known, else from `items.count == limit`.
    public static func make(items: [Item], request: PageRequest, total: Int?) -> Page {
        let end = request.offset + items.count
        let more: Bool
        if let total {
            more = !items.isEmpty && end < total
        } else {
            more = !items.isEmpty && items.count >= request.limit
        }
        return Page(items: items, offset: request.offset, total: total, nextOffset: more ? end : nil)
    }

    /// A complete list in one page (folder, small lists).
    public static func last(_ items: [Item]) -> Page {
        Page(items: items, offset: 0, total: items.count, nextOffset: nil)
    }
}

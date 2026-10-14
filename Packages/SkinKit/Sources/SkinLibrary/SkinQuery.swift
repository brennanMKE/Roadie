import Foundation

/// One page of the skin browser's listing: optional text (name and readme), a status set and a window.
public struct SkinQuery: Hashable, Sendable {
    /// Trimmed by the caller; fewer than two characters means "no text" (a one-letter prefix matches most of the index).
    public var text: String
    public var statuses: Set<SkinStatus>
    public var limit: Int
    public var offset: Int

    public static let loadable: Set<SkinStatus> = [.ok, .partial]
    public static let minimumTextLength = 2

    public var hasText: Bool { text.count >= Self.minimumTextLength }

    public init(
        text: String = "", statuses: Set<SkinStatus> = Set(SkinStatus.allCases), limit: Int = 200, offset: Int = 0
    ) {
        self.text = text
        self.statuses = statuses
        self.limit = limit
        self.offset = offset
    }
}

public enum SkinNeighborDirection: Sendable { case next, previous }

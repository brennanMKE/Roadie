import Darwin
import Foundation

/// One playlist row as Jump to File searches it (#0175). Empty strings for unknown fields.
public struct JumpToFileEntry: Hashable, Sendable {
    public var artist: String
    public var title: String
    public var album: String
    /// The file name for a local file; "" for a remote queue row.
    public var fileName: String

    public init(artist: String, title: String, album: String = "", fileName: String = "") {
        self.artist = artist
        self.title = title
        self.album = album
        self.fileName = fileName
    }
}

/// Winamp's Jump to File filter over a playlist (#0175): built once per queue, queried per keystroke.
public struct JumpToFileIndex: Sendable {
    /// Every row's folded haystack, UTF-8, back to back.
    private let bytes: [UInt8]
    /// Row `i` is `bytes[starts[i]..<starts[i + 1]]`.
    private let starts: [Int]

    public init(_ entries: [JumpToFileEntry]) {
        var bytes: [UInt8] = []
        var starts: [Int] = [0]
        starts.reserveCapacity(entries.count + 1)
        for entry in entries {
            // `\n` separates fields; tokens never hold whitespace, so a token can't match across two fields.
            let haystack = "\(entry.artist) - \(entry.title)\n\(entry.album)\n\(entry.fileName)"
            bytes.append(contentsOf: Self.fold(haystack).utf8)
            starts.append(bytes.count)
        }
        self.bytes = bytes
        self.starts = starts
    }

    public var count: Int { starts.count - 1 }

    /// Row indices, in playlist order, whose text contains every token of `query`. An empty or whitespace-only
    /// query gives every row.
    public func matches(_ query: String) -> [Int] {
        matches(query, isCancelled: { false }) ?? []
    }

    /// The same, but gives up and returns nil when `isCancelled()` turns true (checked every 1,024 rows).
    public func matches(_ query: String, isCancelled: () -> Bool) -> [Int]? {
        // Longest token first, so non-matching rows fail sooner.
        let tokens = Self.tokens(query).map { Array($0.utf8) }.sorted { $0.count > $1.count }
        if tokens.isEmpty { return isCancelled() ? nil : Array(0..<count) }
        var result: [Int] = []
        let finished = bytes.withUnsafeBufferPointer { buffer -> Bool in
            for row in 0..<count {
                if row & 1023 == 0, isCancelled() { return false }
                let start = starts[row]
                let length = starts[row + 1] - start
                guard length > 0, let base = buffer.baseAddress else { continue }
                var all = true
                for token in tokens {
                    let found = token.withUnsafeBufferPointer { t in
                        memmem(base + start, length, t.baseAddress, t.count) != nil
                    }
                    if !found { all = false; break }
                }
                if all { result.append(row) }
            }
            return true
        }
        return finished ? result : nil
    }

    /// Case-, diacritic- and width-insensitive folding, locale-independent.
    public static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
    }

    /// `fold(query)` split on whitespace and newlines, empty pieces dropped.
    public static func tokens(_ query: String) -> [String] {
        fold(query).components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }
    }
}

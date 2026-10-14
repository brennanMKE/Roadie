import Foundation
import MusicBackendKit

public enum MAMediaKind: String, Hashable, Sendable, CaseIterable {
    case artist, album, track, playlist

    /// The command namespace: `music/<plural>/...`.
    var plural: String { rawValue + "s" }

    public var mediaKind: MediaKind {
        switch self {
        case .artist: .artist
        case .album: .album
        case .track: .track
        case .playlist: .playlist
        }
    }

    public init(_ kind: MediaKind) {
        switch kind {
        case .artist: self = .artist
        case .album: self = .album
        case .track: self = .track
        case .playlist: self = .playlist
        }
    }
}

/// `<provider>://<type>/<id>`, e.g. `library://album/27`. The id may contain `/`.
public struct MAURI: Hashable, Sendable {
    public var provider: String
    public var mediaType: MAMediaKind
    public var itemID: String

    public init(provider: String, mediaType: MAMediaKind, itemID: String) {
        self.provider = provider
        self.mediaType = mediaType
        self.itemID = itemID
    }

    public static func parse(_ string: String) -> MAURI? {
        guard let separator = string.range(of: "://") else { return nil }
        let provider = String(string[..<separator.lowerBound])
        let rest = string[separator.upperBound...]
        guard !provider.isEmpty, let slash = rest.firstIndex(of: "/") else { return nil }
        guard let kind = MAMediaKind(rawValue: String(rest[..<slash])) else { return nil }
        let id = String(rest[rest.index(after: slash)...])
        guard !id.isEmpty else { return nil }
        return MAURI(provider: provider, mediaType: kind, itemID: id)
    }

    public var string: String { "\(provider)://\(mediaType.rawValue)/\(itemID)" }
}

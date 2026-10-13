import Foundation

/// A plex.tv PIN. `Decodable` only: it can carry the token, so it must never be encoded,
/// printed or reflected. Not `Codable`, not `Encodable`.
public struct PlexPin: Hashable, Sendable, Decodable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public var id: Int
    public var code: String
    /// Seconds, from plex.tv (about 1800).
    public var expiresIn: Int?
    /// ISO 8601 text, kept as text; the deadline uses `expiresIn` and the local clock.
    public var expiresAt: String?
    /// Decoded from a string straight into a `PlexToken`; nil until the user has signed in.
    public var authToken: PlexToken?

    public var isClaimed: Bool { authToken != nil }
    public var description: String { "PlexPin(claimed: \(isClaimed))" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: []) }

    private enum CodingKeys: String, CodingKey {
        case id, code, expiresIn, expiresAt, authToken
    }

    public init(id: Int, code: String, expiresIn: Int? = nil, expiresAt: String? = nil, authToken: PlexToken? = nil) {
        self.id = id
        self.code = code
        self.expiresIn = expiresIn
        self.expiresAt = expiresAt
        self.authToken = authToken
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(Int.self, forKey: .id)
        code = try container.decode(String.self, forKey: .code)
        expiresIn = try container.decodeIfPresent(Int.self, forKey: .expiresIn)
        expiresAt = try container.decodeIfPresent(String.self, forKey: .expiresAt)
        if let text = try container.decodeIfPresent(String.self, forKey: .authToken), !text.isEmpty {
            authToken = PlexToken(text)
        } else {
            authToken = nil
        }
    }
}

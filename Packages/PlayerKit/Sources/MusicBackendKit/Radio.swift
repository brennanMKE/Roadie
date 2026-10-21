import Foundation

extension BackendCapabilities {
    /// Radio stations: `radios(page:)`, `addRadio(url:name:)` (#0147).
    public static let radio = BackendCapabilities(rawValue: 1 << 8)
}

/// A radio station in the library (#0147). Plays by its id like any other item.
public struct LibraryRadio: Identifiable, Hashable, Sendable {
    public var id: MediaID
    public var name: String
    public var artwork: ArtworkRef?
    /// nil when the backend doesn't say.
    public var isFavorite: Bool?

    public init(id: MediaID, name: String, artwork: ArtworkRef? = nil, isFavorite: Bool? = nil) {
        self.id = id
        self.name = name
        self.artwork = artwork
        self.isFavorite = isFavorite
    }
}

/// Backends without radio have none to list or add.
extension MusicBackend {
    public func radios(page: PageRequest) async throws -> Page<LibraryRadio> {
        throw MusicBackendError.unsupported(.radio)
    }

    public func addRadio(url: String, name: String) async throws -> LibraryRadio {
        throw MusicBackendError.unsupported(.radio)
    }

    public func favoriteRadios(page: PageRequest) async throws -> Page<LibraryRadio> {
        throw MusicBackendError.unsupported(.favorites)
    }
}

/// What "Add Radio URL…" accepts: an http(s) URL with a host. The name defaults to the host.
public enum RadioURLInput {
    public static func parse(_ text: String, name: String = "") -> (url: String, name: String)? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https", let host = url.host, !host.isEmpty
        else { return nil }
        let title = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return (trimmed, title.isEmpty ? host : title)
    }
}

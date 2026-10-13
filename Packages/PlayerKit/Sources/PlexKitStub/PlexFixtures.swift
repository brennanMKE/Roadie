import Foundation

/// Recorded Plex answers (scrubbed by `scripts/record-plex-fixtures.sh`).
public enum PlexFixture: String, CaseIterable, Sendable {
    case identity
    case sections
    case artistsPage = "artists-page"
    case albumsPage = "albums-page"
    case tracksPage = "tracks-page"
    case tracksLastPage = "tracks-last-page"
    case artistChildren = "artist-children"
    case albumChildren = "album-children"
    case tracksSearch = "tracks-search"

    public struct Missing: Error { public var name: String }

    public var data: Data {
        get throws {
            guard let url = Bundle.module.url(forResource: rawValue, withExtension: "json", subdirectory: "Fixtures") else {
                throw Missing(name: rawValue)
            }
            return try Data(contentsOf: url)
        }
    }
}

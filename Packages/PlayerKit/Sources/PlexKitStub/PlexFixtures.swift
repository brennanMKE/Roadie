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
    /// plex.tv answers, hand-written with fake values (never recorded).
    case pinCreated = "pin-created"
    case pinClaimed = "pin-claimed"
    case resources

    public struct Missing: Error { public var name: String }

    public var subdirectory: String {
        switch self {
        case .pinCreated, .pinClaimed, .resources: "Fixtures/plextv"
        default: "Fixtures"
        }
    }

    public var data: Data {
        get throws {
            guard let url = Bundle.module.url(forResource: rawValue, withExtension: "json", subdirectory: subdirectory) else {
                throw Missing(name: rawValue)
            }
            return try Data(contentsOf: url)
        }
    }
}

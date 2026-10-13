import Foundation

/// The Plex settings that are not secrets: the address as typed, the server's identity,
/// and the chosen music library. Deliberately holds no token.
public struct PlexServerSelection: Hashable, Sendable, Codable {
    /// Raw text; normalized on every use.
    public var address: String
    /// From the last successful connection test.
    public var machineIdentifier: String?
    /// `PlexLibrarySection.key`, or nil when none is chosen yet.
    public var librarySectionKey: String?

    public init(address: String = "", machineIdentifier: String? = nil, librarySectionKey: String? = nil) {
        self.address = address
        self.machineIdentifier = machineIdentifier
        self.librarySectionKey = librarySectionKey
    }

    public enum Change: Hashable, Sendable { case none, serverChanged, libraryMissing, autoSelected }

    /// Records a successful connection. A different `machineIdentifier` clears the selected library;
    /// so does a library the server no longer lists. With exactly one music library and nothing
    /// selected, it is selected. When several apply, the first of server changed, library missing,
    /// auto-selected is returned.
    @discardableResult
    public mutating func apply(_ connection: PlexConnection) -> Change {
        var change = Change.none
        if let saved = machineIdentifier, saved != connection.identity.machineIdentifier {
            librarySectionKey = nil
            change = .serverChanged
        }
        machineIdentifier = connection.identity.machineIdentifier

        if let key = librarySectionKey, !connection.musicSections.contains(where: { $0.key == key }) {
            librarySectionKey = nil
            if change == .none { change = .libraryMissing }
        }
        if librarySectionKey == nil, connection.musicSections.count == 1 {
            librarySectionKey = connection.musicSections[0].key
            if change == .none { change = .autoSelected }
        }
        return change
    }

    /// The selected section among `sections`, if it is still there.
    public func selectedSection(in sections: [PlexLibrarySection]) -> PlexLibrarySection? {
        guard let librarySectionKey else { return nil }
        return sections.first { $0.key == librarySectionKey }
    }
}

import Foundation

/// One artist as the UI shows it: every `LibraryArtist` whose name keys the same.
public struct ArtistGroup: Identifiable, Hashable, Sendable {
    /// The id of the group whose members have no usable name.
    public static let unknownID = "<unknown>"

    /// `ArtistName.key` of the members; `unknownID` for the empty key.
    public var id: String
    /// `ArtistName.display` of the first member seen. Fixed for the life of the group so rows do not rename as pages load.
    public var name: String
    public var sortName: String?
    /// Members in the order they were seen (backend order); never empty.
    public var members: [LibraryArtist]
    /// The first member's artwork, or the first later member that has one.
    public var artwork: ArtworkRef?

    public var memberIDs: [MediaID] { members.map(\.id) }
    public var isMerged: Bool { members.count > 1 }

    public init(id: String, name: String, sortName: String?, members: [LibraryArtist], artwork: ArtworkRef?) {
        self.id = id
        self.name = name
        self.sortName = sortName
        self.members = members
        self.artwork = artwork
    }
}

/// Accumulates artists page by page. Value type; the browser keeps one per listing.
public struct ArtistGrouper: Sendable {
    /// Groups in first-seen order. A group keeps its position when later members join.
    public private(set) var groups: [ArtistGroup] = []
    private var indexByID: [ArtistGroup.ID: Int] = [:]
    private var seen: Set<MediaID> = []

    public init() {}

    /// Adds a page. An artist whose `id` was already seen is ignored (page overlap).
    /// Returns the ids of groups created or changed.
    @discardableResult
    public mutating func add(_ artists: [LibraryArtist]) -> Set<ArtistGroup.ID> {
        var touched: Set<ArtistGroup.ID> = []
        for artist in artists where seen.insert(artist.id).inserted {
            let key = ArtistName.key(artist.name)
            let id = key.isEmpty ? ArtistGroup.unknownID : key
            if let index = indexByID[id] {
                groups[index].members.append(artist)
                if groups[index].artwork == nil { groups[index].artwork = artist.artwork }
            } else {
                indexByID[id] = groups.count
                groups.append(ArtistGroup(
                    id: id, name: ArtistName.display(artist.name), sortName: artist.sortName,
                    members: [artist], artwork: artist.artwork))
            }
            touched.insert(id)
        }
        return touched
    }

    public mutating func removeAll() {
        groups = []
        indexByID = [:]
        seen = []
    }

    /// The group holding the artist with this id, if any.
    public func group(containing id: MediaID) -> ArtistGroup? {
        groups.first { $0.members.contains { $0.id == id } }
    }

    /// One-shot grouping (search results).
    public static func group(_ artists: [LibraryArtist]) -> [ArtistGroup] {
        var grouper = ArtistGrouper()
        grouper.add(artists)
        return grouper.groups
    }
}

import MusicBackendKit
import Testing
@testable import LibraryBrowser

struct PlaylistGroupingTests {
    private func playlist(
        _ name: String, _ source: PlaylistSource, editable: Bool = false, dynamic: Bool = false, count: Int? = nil,
        owner: String? = nil
    ) -> LibraryPlaylist {
        LibraryPlaylist(
            id: MediaID(.playlist, "library://playlist/\(name)"), name: name, trackCount: count, isEditable: editable,
            isDynamic: dynamic, owner: owner, source: source)
    }

    @Test func groupsAreMineThenBuiltInThenProvidersInFirstSeenOrder() {
        let items = [
            playlist("Discover Weekly", .provider(name: "Spotify")),
            playlist("Random", .builtIn),
            playlist("Road Trip", .user, editable: true),
            playlist("Station", .provider(name: "Tidal"), editable: true),
            playlist("Chill Hits", .provider(name: "Spotify")),
            playlist("Sunday", .user, editable: true),
        ]
        let groups = PlaylistGrouping.groups(items)
        #expect(groups.map(\.kind) == [.mine, .builtIn, .provider("Spotify"), .provider("Tidal")])
        #expect(groups[0].playlists.map(\.name) == ["Road Trip", "Sunday"])
        #expect(groups[2].playlists.map(\.name) == ["Discover Weekly", "Chill Hits"])
        let rows = PlaylistGrouping.rows(items)
        #expect(rows.count == items.count + groups.count)
        #expect(rows.first == .header(groups[0]))
    }

    @Test func providerGroupIsNamedAndSuffixedWhenReadOnly() {
        let groups = PlaylistGrouping.groups([
            playlist("Road Trip", .user, editable: true),
            playlist("Random", .builtIn),
            playlist("Discover Weekly", .provider(name: "Spotify")),
            playlist("Station", .provider(name: "Tidal"), editable: true),
        ])
        #expect(groups.map(\.title) == ["My Playlists", "Built-in", "Spotify · read-only", "Tidal"])
        #expect(groups.map(\.isReadOnly) == [false, false, true, false])
    }

    @Test func countAndDetailLine() {
        let dynamic = playlist("Infinite", .builtIn, dynamic: true, count: 5, owner: "Music Assistant")
        #expect(PlaylistGrouping.countText(dynamic) == "∞")
        #expect(PlaylistGrouping.countText(playlist("A", .user, count: 24)) == "24")
        #expect(PlaylistGrouping.countText(playlist("A", .user)) == nil)
        #expect(PlaylistGrouping.detailLine(dynamic) == "Built-in · Read-only · Dynamic")
        #expect(
            PlaylistGrouping.detailLine(playlist("D", .provider(name: "Spotify"), owner: "Spotify Editors"))
                == "Spotify · Spotify Editors · Read-only")
        #expect(PlaylistGrouping.detailLine(playlist("R", .user, editable: true, owner: "Brennan")) == "Music Assistant · Brennan")
    }

    /// #0221: the user's playlist owned by "Music Assistant" groups under My Playlists, without a doubled owner.
    @Test func partyGroupsUnderMyPlaylists() {
        let party = playlist("Party", .user, editable: true, owner: "Music Assistant")
        let groups = PlaylistGrouping.groups([
            playlist("Random", .builtIn, owner: "Music Assistant"), party,
            playlist("Recently added", .builtIn, owner: "Music Assistant"),
        ])
        #expect(groups.map(\.kind) == [.mine, .builtIn])
        #expect(groups[0].playlists.map(\.name) == ["Party"])
        #expect(PlaylistGrouping.detailLine(party) == "Music Assistant")
    }
}

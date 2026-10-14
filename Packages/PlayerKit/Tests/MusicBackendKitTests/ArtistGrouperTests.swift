import Testing
@testable import MusicBackendKit

@Suite struct ArtistGrouperTests {
    private func artist(_ id: String, _ name: String, art: String? = nil) -> LibraryArtist {
        LibraryArtist(id: MediaID(.artist, id), name: name, artwork: art.map { ArtworkRef(rawValue: $0) })
    }

    @Test func mergesDuplicatesAcrossPages() {
        var grouper = ArtistGrouper()
        grouper.add([artist("1", "AJ & Jordan"), artist("2", "Aerosmith")])
        let touched = grouper.add([artist("3", "AJ and Jordan;")])
        #expect(grouper.groups.count == 2)
        let group = grouper.groups[0]
        #expect(group.id == "aj & jordan")
        #expect(group.memberIDs == [MediaID(.artist, "1"), MediaID(.artist, "3")])
        #expect(group.name == "AJ & Jordan")
        #expect(group.isMerged)
        #expect(touched == ["aj & jordan"])
    }

    @Test func keepsFirstSeenOrder() {
        var grouper = ArtistGrouper()
        grouper.add([artist("1", "Foo"), artist("2", "Foo Bar")])
        grouper.add([artist("3", "Foo;")])
        #expect(grouper.groups.map(\.id) == ["foo", "foo bar"])
        #expect(grouper.groups[0].members.count == 2)
    }

    @Test func nameIsFixedByTheFirstMember() {
        var grouper = ArtistGrouper()
        grouper.add([artist("1", "AJ and Jordan")])
        grouper.add([artist("2", "AJ & Jordan")])
        #expect(grouper.groups.count == 1)
        #expect(grouper.groups[0].name == "AJ and Jordan")
    }

    @Test func artworkFillsInFromALaterMember() {
        var grouper = ArtistGrouper()
        grouper.add([artist("1", "Foo")])
        #expect(grouper.groups[0].artwork == nil)
        grouper.add([artist("2", "foo", art: "/library/metadata/2/thumb/1")])
        grouper.add([artist("3", "FOO", art: "/library/metadata/3/thumb/1")])
        #expect(grouper.groups[0].artwork == ArtworkRef(rawValue: "/library/metadata/2/thumb/1"))
    }

    @Test func ignoresARepeatedID() {
        var grouper = ArtistGrouper()
        let one = artist("1", "Foo")
        grouper.add([one])
        let touched = grouper.add([one])
        #expect(grouper.groups[0].members.count == 1)
        #expect(touched.isEmpty)
    }

    @Test func emptyNamesShareTheUnknownGroup() {
        var grouper = ArtistGrouper()
        grouper.add([artist("1", ""), artist("2", ";")])
        #expect(grouper.groups.count == 1)
        #expect(grouper.groups[0].id == ArtistGroup.unknownID)
        #expect(grouper.groups[0].name == "Unknown Artist")
    }

    @Test func groupMatchesIncremental() {
        let all = [
            artist("1", "AJ & Jordan"), artist("2", "Aerosmith"), artist("3", "AJ and Jordan"),
            artist("4", "aerosmith;"), artist("5", "Zed"),
        ]
        var grouper = ArtistGrouper()
        grouper.add(Array(all[..<2]))
        grouper.add(Array(all[2...]))
        #expect(ArtistGrouper.group(all) == grouper.groups)
    }

    @Test func removeAllForgetsSeenIDs() {
        var grouper = ArtistGrouper()
        let one = artist("1", "Foo")
        grouper.add([one])
        grouper.removeAll()
        #expect(grouper.groups.isEmpty)
        grouper.add([one])
        #expect(grouper.groups.count == 1)
    }

    @Test func findsTheGroupHoldingAMember() {
        var grouper = ArtistGrouper()
        grouper.add([artist("1", "AJ & Jordan"), artist("2", "AJ and Jordan")])
        #expect(grouper.group(containing: MediaID(.artist, "2"))?.id == "aj & jordan")
        #expect(grouper.group(containing: MediaID(.artist, "9")) == nil)
    }
}

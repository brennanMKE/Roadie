import Foundation
import Testing
import PlexKit

struct PlexServerSelectionTests {
    private func connection(id: String = "AAAA", keys: [String]) -> PlexConnection {
        PlexConnection(
            baseURL: URL(string: "http://joe:32400")!,
            identity: PlexIdentity(machineIdentifier: id, version: "1"),
            musicSections: keys.map { PlexLibrarySection(key: $0, title: "Music \($0)", type: "artist") })
    }

    @Test func firstConnectionSavesIdentifier() {
        var selection = PlexServerSelection(address: "joe")
        #expect(selection.apply(connection(keys: ["5", "6"])) == .none)
        #expect(selection.machineIdentifier == "AAAA")
        #expect(selection.librarySectionKey == nil)
    }

    @Test func sameServerKeepsLibrary() {
        var selection = PlexServerSelection(address: "joe", machineIdentifier: "AAAA", librarySectionKey: "5")
        #expect(selection.apply(connection(keys: ["5", "6"])) == .none)
        #expect(selection.librarySectionKey == "5")
    }

    @Test func changedServerClearsLibrary() {
        var selection = PlexServerSelection(address: "joe", machineIdentifier: "AAAA", librarySectionKey: "5")
        #expect(selection.apply(connection(id: "BBBB", keys: ["5", "6"])) == .serverChanged)
        #expect(selection.librarySectionKey == nil)
        #expect(selection.machineIdentifier == "BBBB")

        var single = PlexServerSelection(address: "joe", machineIdentifier: "AAAA", librarySectionKey: "5")
        #expect(single.apply(connection(id: "BBBB", keys: ["9"])) == .serverChanged)
        #expect(single.librarySectionKey == "9")
    }

    @Test func missingLibraryIsCleared() {
        var selection = PlexServerSelection(address: "joe", machineIdentifier: "AAAA", librarySectionKey: "5")
        #expect(selection.apply(connection(keys: ["7", "8"])) == .libraryMissing)
        #expect(selection.librarySectionKey == nil)
    }

    @Test func singleMusicLibraryIsAutoSelected() {
        var selection = PlexServerSelection(address: "joe")
        #expect(selection.apply(connection(keys: ["5"])) == .autoSelected)
        #expect(selection.librarySectionKey == "5")

        var two = PlexServerSelection(address: "joe")
        two.apply(connection(keys: ["5", "6"]))
        #expect(two.librarySectionKey == nil)
    }

    @Test func selectedSectionLooksUpByKey() {
        let sections = connection(keys: ["5", "6"]).musicSections
        #expect(PlexServerSelection(librarySectionKey: "6").selectedSection(in: sections)?.key == "6")
        #expect(PlexServerSelection(librarySectionKey: "7").selectedSection(in: sections) == nil)
        #expect(PlexServerSelection().selectedSection(in: sections) == nil)
    }

    @Test func roundTripsThroughJSONWithoutSecrets() throws {
        let selection = PlexServerSelection(address: "joe", machineIdentifier: "AAAA", librarySectionKey: "5")
        let data = try JSONEncoder().encode(selection)
        #expect(try JSONDecoder().decode(PlexServerSelection.self, from: data) == selection)
        #expect(!String(decoding: data, as: UTF8.self).lowercased().contains("token"))
    }
}

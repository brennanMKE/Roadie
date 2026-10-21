import Foundation
import MusicBackendKit
import MusicBackendStub
import Testing
@testable import LibraryBrowser

@MainActor
struct RadioSectionTests {
    @Test func radioSectionNeedsTheCapability() {
        let (_, plain) = makeModel(capabilities: [.search, .playlists, .favorites])
        #expect(!plain.sections.contains(.radio))
        let (_, withRadio) = makeModel(capabilities: [.search, .playlists, .favorites, .radio])
        #expect(withRadio.sections == [.artists, .albums, .playlists, .favorites, .radio])
        #expect(FavoriteKind(.radio) == .radios)
        #expect(FavoriteKind.radios.mediaKind == .radio)
    }

    @Test func addRadioValidatesTheURL() async {
        #expect(RadioURLInput.parse("  https://stream.example/live ")?.name == "stream.example")
        #expect(RadioURLInput.parse("http://a.example/x", name: "Mine")?.name == "Mine")
        #expect(RadioURLInput.parse("ftp://a.example/x") == nil)
        #expect(RadioURLInput.parse("not a url") == nil)
        let (_, without) = makeModel(capabilities: [.search])
        #expect(await without.addRadio(url: "https://stream.example/live") != nil)
        let (_, model) = makeModel(capabilities: [.search, .radio])
        #expect(await model.addRadio(url: "nope") == "Enter an http or https stream URL.")
        // The stub has no radio, so a valid URL reaches the backend and its unsupported error comes back.
        #expect(await model.addRadio(url: "https://stream.example/live") != nil)
    }
}

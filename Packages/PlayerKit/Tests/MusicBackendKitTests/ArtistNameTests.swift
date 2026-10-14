import Testing
@testable import MusicBackendKit

@Suite struct ArtistNameTests {
    @Test func ampersandAndTheWordAndShareAKey() {
        for name in ["AJ & Jordan", "AJ and Jordan", "AJ AND Jordan", "AJ&Jordan"] {
            #expect(ArtistName.key(name) == "aj & jordan", "\(name)")
        }
    }

    @Test func trailingSemicolonIsDropped() {
        #expect(ArtistName.key("AJ & Jordan;") == ArtistName.key("AJ & Jordan"))
        #expect(ArtistName.key("AJ & Jordan ;") == ArtistName.key("AJ & Jordan"))
        #expect(ArtistName.key("AJ & Jordan;;") == ArtistName.key("AJ & Jordan"))
        #expect(ArtistName.display("AJ & Jordan;") == "AJ & Jordan")
        #expect(ArtistName.display("AJ & Jordan ;") == "AJ & Jordan")
    }

    @Test func caseIsFolded() {
        #expect(ArtistName.key("aerosmith") == "aerosmith")
        #expect(ArtistName.key("Aerosmith") == "aerosmith")
        #expect(ArtistName.display("aerosmith") == "aerosmith")
    }

    @Test func whitespaceIsCollapsed() {
        #expect(ArtistName.display("  10,000   Maniacs ") == "10,000 Maniacs")
        #expect(ArtistName.key("  10,000   Maniacs ") == "10,000 maniacs")
    }

    @Test func andInsideAWordIsKept() {
        #expect(ArtistName.key("Sandy Denny") == "sandy denny")
        #expect(ArtistName.key("Band of Horses") == "band of horses")
        #expect(ArtistName.key("Andy") == "andy")
    }

    @Test func distinctNamesStayDistinct() {
        #expect(ArtistName.key("AJ & Jordan") != ArtistName.key("AJ & Jordana"))
        #expect(ArtistName.key("Beatles") != ArtistName.key("The Beatles"))
        #expect(ArtistName.key("Bj\u{00F6}rk") != ArtistName.key("Bjork"))
    }

    @Test func emptyNamesAreUnknown() {
        for name in ["", ";", "  ;; "] {
            #expect(ArtistName.display(name) == ArtistName.unknown, "\(name)")
            #expect(ArtistName.key(name) == "", "\(name)")
        }
    }

    @Test func aRealArtistCalledUnknownArtistIsNotTheEmptyKey() {
        #expect(ArtistName.key("Unknown Artist") == "unknown artist")
    }

    @Test func keyAndDisplayAreIdempotent() {
        let examples = [
            "AJ & Jordan", "AJ and Jordan", "AJ&Jordan", "AJ & Jordan;", "AJ & Jordan ;;", "aerosmith",
            "  10,000   Maniacs ", "Sandy Denny", "Bj\u{00F6}rk", "", ";",
        ]
        for name in examples {
            let key = ArtistName.key(name)
            let display = ArtistName.display(name)
            #expect(ArtistName.key(key) == key, "\(name)")
            #expect(ArtistName.display(display) == display, "\(name)")
            // An empty name displays as "Unknown Artist", which is a name of its own; every other name round-trips.
            if !key.isEmpty { #expect(ArtistName.key(display) == key, "\(name)") }
        }
    }
}

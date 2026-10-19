import Foundation
import Testing
@testable import MusicBackendKit

struct NowPlayingTests {
    @Test func elapsedExtrapolatesOnlyWhilePlaying() {
        let t = Date(timeIntervalSince1970: 1_800_000_000)
        var snapshot = NowPlaying(output: OutputDevice.thisMacID, state: .playing, duration: 100, elapsed: 10, updatedAt: t)
        #expect(snapshot.elapsed(at: t.addingTimeInterval(5)) == 15)
        snapshot.state = .paused
        #expect(snapshot.elapsed(at: t.addingTimeInterval(5)) == 10)
        snapshot.state = .playing
        #expect(snapshot.elapsed(at: t.addingTimeInterval(500)) == 100)
        #expect(snapshot.elapsed(at: t.addingTimeInterval(-5)) == 10)
    }

    @Test func idleSnapshotHasNoItem() {
        let idle = NowPlaying.idle(on: OutputDevice.thisMacID)
        #expect(idle.state == .stopped)
        #expect(idle.item == nil)
        #expect(idle.title == nil)
        #expect(idle.elapsed == 0)
        #expect(idle.output == OutputDevice.thisMacID)
    }
}

struct MediaIDTests {
    @Test func codableRoundTrip() throws {
        let id = MediaID(.album, "library://album/42")
        let data = try JSONEncoder().encode(id)
        #expect(try JSONDecoder().decode(MediaID.self, from: data) == id)
    }

    @Test func descriptionShowsKindAndValue() {
        #expect(MediaID(.track, "3685").description == "track:3685")
    }

    @Test func thisMacHasAStableID() {
        #expect(OutputDevice.thisMac.id.rawValue == "this-mac")
        #expect(OutputDevice.thisMac.kind == .thisMac)
    }

    @Test func searchResultsEmpty() {
        #expect(SearchResults.empty.isEmpty)
    }
}

struct MusicBackendErrorTests {
    @Test func descriptionsAreShortAndNeverEmpty() {
        let cases: [MusicBackendError] = [
            .notConfigured("Set it up."), .notConnected, .unreachable("Can't reach it."), .unauthorized,
            .notFound(MediaID(.track, "1")), .unsupported(.playlists), .unknownOutput(.init(rawValue: "x")),
            .backend("Broke."),
        ]
        for error in cases {
            let text = error.localizedDescription
            #expect(!text.isEmpty)
            #expect(text.count < 200)
        }
    }
}

struct OutputDeviceTests {
    @Test func outputDeviceIsNotAGroupByDefault() {
        #expect(!OutputDevice(id: OutputDevice.ID(rawValue: "x"), name: "X", kind: .remote).isGroup)
        #expect(!OutputDevice.thisMac.isGroup)
    }
}

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

    private static let remote = OutputDevice.ID(rawValue: "homepod")
    private static let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    private static func remoteSnapshot(_ state: NowPlaying.State, elapsed: TimeInterval, duration: TimeInterval = 300) -> NowPlaying {
        NowPlaying(output: remote, state: state, duration: duration, elapsed: elapsed, updatedAt: t0)
    }

    @Test func remoteClockAnchorIsNilOnThisMac() {
        let snapshot = Self.remoteSnapshot(.playing, elapsed: 10.7)
        #expect(snapshot.remoteClockAnchor(selected: OutputDevice.thisMacID) == nil)
    }

    @Test func remoteClockAnchorIsNilUnlessPlaying() {
        for state in [NowPlaying.State.paused, .stopped, .loading] {
            #expect(Self.remoteSnapshot(state, elapsed: 10.7).remoteClockAnchor(selected: Self.remote) == nil)
        }
    }

    @Test func remoteClockAnchorAlignsToWholeSeconds() throws {
        let snapshot = Self.remoteSnapshot(.playing, elapsed: 10.7)
        let anchor = try #require(snapshot.remoteClockAnchor(selected: Self.remote))
        let expected = Self.t0.addingTimeInterval(-0.7 + NowPlaying.clockLead)
        #expect(abs(anchor.timeIntervalSince(expected)) < 1e-4)
        // The anchor itself is before `updatedAt` (elapsed(at:) does not extrapolate backwards), so check the
        // first tick after the snapshot: it lands `clockLead` past a whole second.
        let fraction = snapshot.elapsed(at: anchor.addingTimeInterval(1)).truncatingRemainder(dividingBy: 1)
        #expect(abs(fraction - NowPlaying.clockLead) < 1e-4)
    }

    @Test(arguments: [0.0, 10.0, 10.999, 59.5])
    func remoteClockTicksAdvanceOneSecondEach(start: TimeInterval) throws {
        let snapshot = Self.remoteSnapshot(.playing, elapsed: start)
        let anchor = try #require(snapshot.remoteClockAnchor(selected: Self.remote))
        let seconds = (0..<5).map { Int(snapshot.elapsed(at: anchor.addingTimeInterval(TimeInterval($0)))) }
        for (a, b) in zip(seconds, seconds.dropFirst()) { #expect(b == a + 1) }
    }

    @Test func remoteClockTicksClampAtDuration() throws {
        let snapshot = Self.remoteSnapshot(.playing, elapsed: 98.3, duration: 100)
        let anchor = try #require(snapshot.remoteClockAnchor(selected: Self.remote))
        let values = (0..<6).map { snapshot.elapsed(at: anchor.addingTimeInterval(TimeInterval($0))) }
        #expect(values.last == 100)
        #expect(values.suffix(3).allSatisfy { $0 == 100 })
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

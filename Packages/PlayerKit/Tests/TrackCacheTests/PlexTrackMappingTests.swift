import AudioCore
import Foundation
import PlexKit
import PlexKitStub
import Testing
@testable import TrackCache

/// The first track of the recorded `tracks-page` fixture.
func fixtureTrack() throws -> PlexTrack {
    let data = try PlexFixture.tracksPage.data
    let root = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    let container = try #require(root["MediaContainer"] as? [String: Any])
    let metadata = try #require((container["Metadata"] as? [[String: Any]])?.first)
    return try JSONDecoder().decode(PlexTrack.self, from: JSONSerialization.data(withJSONObject: metadata))
}

let fixtureMachineIdentifier = "0123456789abcdef0123456789abcdef01234567"

struct PlexTrackMappingTests {
    @Test func cacheKeyIsServerPartAndStamp() throws {
        let part = try #require(try fixtureTrack().primaryPart)
        let key = PlexCacheKey.key(machineIdentifier: fixtureMachineIdentifier, part: part)
        #expect(key == "\(fixtureMachineIdentifier)-5010-1791856627")
        #expect(PlexCacheKey.machineIdentifier(of: key) == fixtureMachineIdentifier)

        var unstamped = part
        unstamped.key = "/library/parts/5010/file.m4a"
        #expect(PlexCacheKey.key(machineIdentifier: "abc", part: unstamped) == "abc-5010-0")

        let hostile = PlexCacheKey.key(machineIdentifier: "../etc/x", part: part)
        #expect(hostile == "etcx-5010-1791856627")
        #expect(!hostile.contains("/") && !hostile.contains("."))
    }

    @Test func trackFromPlexTrackCarriesMetadataAndSource() throws {
        let plex = try fixtureTrack()
        let part = try #require(plex.primaryPart)
        let track = try Track(plexTrack: plex, machineIdentifier: fixtureMachineIdentifier)
        #expect(track.title == plex.title)
        #expect(track.artist == plex.grandparentTitle)
        #expect(track.album == plex.parentTitle)
        #expect(track.duration == plex.durationSeconds)
        #expect(track.bitrate == plex.media.first?.bitrate)
        #expect(track.channels == plex.media.first?.audioChannels)
        #expect(track.sampleRate == nil)
        #expect(track.source == .plex(
            partKey: part.key,
            cacheKey: "\(fixtureMachineIdentifier)-5010-1791856627",
            size: 7_147_054))
    }

    @Test func trackWithoutAPartThrows() throws {
        let json = #"{"ratingKey":"1","key":"/library/metadata/1","title":"No file"}"#
        let plex = try JSONDecoder().decode(PlexTrack.self, from: Data(json.utf8))
        #expect(throws: TrackCacheError.notPlexTrack) {
            try Track(plexTrack: plex, machineIdentifier: "abc")
        }
    }
}

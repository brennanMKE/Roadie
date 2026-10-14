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

    private static func json(audioChannels: String, streamChannels: Int) -> Data {
        Data("""
        {"ratingKey":"7","key":"/library/metadata/7","title":"T","Media":[{"id":1,"bitrate":320\(audioChannels),
        "Part":[{"id":9,"key":"/library/parts/9/1/file.mp3","Stream":[
        {"id":2,"streamType":2,"codec":"mp3","samplingRate":44100,"channels":\(streamChannels),"bitrate":256}]}]}]}
        """.utf8)
    }

    @Test func sampleRateAndChannelsFallBackToTheAudioStream() throws {
        let both = try JSONDecoder().decode(PlexTrack.self, from: Self.json(audioChannels: #","audioChannels":2"#, streamChannels: 1))
        let first = try Track(plexTrack: both, machineIdentifier: "abc")
        #expect(first.sampleRate == 44100)
        #expect(first.channels == 2)
        #expect(first.bitrate == 320)

        let noMediaChannels = try JSONDecoder().decode(PlexTrack.self, from: Self.json(audioChannels: "", streamChannels: 1))
        let second = try Track(plexTrack: noMediaChannels, machineIdentifier: "abc")
        #expect(second.channels == 1)
        #expect(second.sampleRate == 44100)
    }
}

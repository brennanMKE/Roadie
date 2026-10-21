import Foundation
import MusicAssistantKitStub
import Testing
@testable import MusicAssistantKit

struct ModelDecodingTests {
    @Test func serverInfoDecodesAllTwelveFields() throws {
        let info = try MAFixture.serverInfo.frames()[0].decode(as: MAServerInfo.self)
        #expect(info.serverID == fixtureServerID)
        #expect(info.serverVersion == "2.10.6")
        #expect(info.schemaVersion == 65)
        #expect(info.minSupportedSchemaVersion == 28)
        #expect(info.baseURL == "http://ma.example:8095")
        #expect(info.homeassistantAddon == true)
        #expect(info.onboardDone == true)
        #expect(info.name == "Music Assistant")
        #expect(info.status == "running")
        #expect(info.internalURL == "http://ma.example:8095")
        #expect(info.externalURL == nil)
        #expect(info.hasRemoteAccess == false)
        let http = try JSONDecoder().decode(MAServerInfo.self, from: MAFixture.infoHTTP.data)
        #expect(http == info)
    }

    @Test func authResultDecodesTheUser() throws {
        let auth = try recordedResult(.authOk).decode(as: MAAuthResult.self)
        #expect(auth.authenticated)
        #expect(auth.user?.role == "admin")
        #expect(auth.user?.displayName == "user")
        #expect(auth.user?.username == "user")
    }

    @Test func artistPageDecodesSlimItems() throws {
        let artists = try recordedResult(.artistsPage).decode(as: [MAArtist].self)
        #expect(artists.count == 3)
        #expect(artists[0].uri == "library://artist/432")
        #expect(artists[0].itemID == "432")
        #expect(artists[0].sortName == "10,000 maniacs")
        #expect(artists[0].metadata?.images == nil)
        let thumb = try #require(artists[1].metadata?.images?.first)
        #expect(thumb.type == "thumb")
        #expect(try #require(thumb.proxyID).hasPrefix("e4225853"))
    }

    @Test func albumPageDecodesArtistsAndYear() throws {
        let albums = try recordedResult(.albumsPage).decode(as: [MAAlbum].self)
        #expect(albums.count == 3)
        #expect(albums[0].name == "")
        #expect(albums[0].year == 1999)
        #expect(albums[0].artists?[0].uri == "library://artist/15")
        #expect(albums[0].providerMappings?[0].itemID == "Aphex Twins")
    }

    @Test func trackPageDecodesNumbersAndFormat() throws {
        let tracks = try recordedResult(.tracksPage).decode(as: [MATrack].self)
        let track = tracks[0]
        #expect(track.uri == "library://track/2000")
        #expect(track.duration == 1167)
        #expect(track.trackNumber == 0)
        #expect(track.discNumber == 0)
        #expect(track.album?.uri == "library://album/206")
        #expect(track.album?.year == 2009)
        let format = try #require(track.providerMappings?.first?.audioFormat)
        #expect(format.bitRate == 192)
        #expect(format.sampleRate == 44100)
        #expect(format.channels == 2)
    }

    @Test func fullItemsDecodeWithNullMetadataFields() throws {
        #expect(try recordedResult(.albumsPageFull).decode(as: [MAAlbum].self).count == 1)
        let tracks = try recordedResult(.tracksPageFull).decode(as: [MATrack].self)
        #expect(tracks.count == 1)
        #expect(tracks[0].metadata?.images == nil)
        #expect(try recordedResult(.artistsPageFull).decode(as: [MAArtist].self).count == 1)
    }

    @Test func playlistPageDecodesFlagsAndImages() throws {
        let playlists = try recordedResult(.playlistsPage).decode(as: [MAPlaylist].self)
        #expect(playlists.count == 3)
        #expect(playlists[2].itemID == "8")
        #expect(playlists[2].isDynamic == true)
        #expect(playlists[0].isDynamic == false)
        #expect(try #require(playlists[0].metadata?.images?.first?.proxyID).hasPrefix("55fac489"))
    }

    @Test func playlistTracksChunksDecode() throws {
        let frames = try MAFixture.playlistTracks.frames()
        #expect(frames.count == 2)
        #expect(try frames[0]["result"]?.decode(as: [MATrack].self).count == 5)
        #expect(try frames[1]["result"]?.decode(as: [MATrack].self).count == 0)
        #expect(frames[0]["partial"] == true)
        #expect(frames[1]["partial"] == false)
    }

    @Test func searchResultsDecodeOnlyTheFourKinds() throws {
        let found = try recordedResult(.search).decode(as: MASearchResults.self)
        #expect(found.tracks.count == 1)
        #expect(found.artists.isEmpty)
        #expect(found.albums.isEmpty)
        #expect(found.playlists.isEmpty)
        #expect(found.tracks[0].uri == "library://track/2000")
        let sparse = try MAJSON.object(["tracks": []]).decode(as: MASearchResults.self)
        #expect(sparse.tracks.isEmpty)
    }

    @Test func playersDecodeWithTheirOptionalFields() throws {
        let players = try recordedResult(.playersAll).decode(as: [MAPlayer].self)
        #expect(players.count == 9)
        #expect(players.filter { $0.currentMedia != nil }.count == 1)
        let sendspin = try #require(players.first { $0.provider == "sendspin" })
        #expect(sendspin.currentMedia?.title == "We Are All Made of Stars")
        #expect(sendspin.hideInUI == true)
        #expect(players.filter { $0.hideInUI == true }.count == 1)
        let universal = players.filter { $0.provider == "universal_player" }
        #expect(universal.count == 4)
        #expect(universal.filter { $0.volumeLevel == nil }.count == 3)
        #expect(players.first { $0.playerID == "ap223aed81fe30" }?.volumeLevel == 20)
        #expect(players.first { $0.playerID == "ap223aed81fe30" }?.needsSetup == true)
        #expect(players.allSatisfy { $0.supportedFeatures != nil })
        #expect(players.contains { $0.supportedFeatures?.contains("play_media") == true })
        #expect(MAPlaybackState("playing") == .playing)
        #expect(MAPlaybackState("something-new") == .unknown)
    }

    @Test func playerDecodesCanGroupWith() throws {
        let players = try recordedResult(.playersAll).decode(as: [MAPlayer].self)
        let player = try #require(players.first { $0.playerID == "ap223aed81fe30" })
        #expect(player.canGroupWith?.contains("ap82fe09484ac9") == true)
    }

    @Test func queuesDecodeItemsAsACount() throws {
        let queues = try recordedResult(.playerQueuesAll).decode(as: [MAPlayerQueue].self)
        #expect(queues.count == 9)
        #expect(queues[0].items == 0)
        #expect(queues[0].currentItem == nil)
        #expect(queues[0].elapsedTimeLastUpdated == 1792014461.1318326)
        #expect(queues[0].repeatMode == "off")
        #expect(try recordedResult(.playerQueueItems).decode(as: [MAQueueItem].self).isEmpty)
    }

    @Test func providersDecode() throws {
        let providers = try recordedResult(.providers).decode(as: [MAProvider].self)
        #expect(providers.count == 3)
        let smb = try #require(providers.first { $0.instanceID == "filesystem_smb--gPeSLx39" })
        #expect(smb.supportedFeatures?.contains("search") == true)
    }

    @Test func envelopeClassifiesEveryRecordedFrameKind() throws {
        func classify(_ fixture: MAFixture) throws -> MAEnvelope {
            MAEnvelope.parse(try fixture.frameTexts()[0])
        }
        guard case .serverInfo(let info) = try classify(.serverInfo) else { Issue.record("server info"); return }
        #expect(info.serverID == fixtureServerID)
        guard case .result(let id, _, let partial) = try classify(.authOk) else { Issue.record("auth"); return }
        #expect(id == "1")
        #expect(!partial)
        guard case .error(_, let code23, _) = try classify(.errorAuth) else { Issue.record("23"); return }
        #expect(code23 == 23)
        guard case .error(_, let code20, _) = try classify(.errorUnauthenticated) else { Issue.record("20"); return }
        #expect(code20 == 20)
        guard case .error(_, let code12, let details) = try classify(.errorUnknownCommand) else { Issue.record("12"); return }
        #expect(code12 == 12)
        #expect(details == "Invalid or unsupported command.")
        guard case .result(_, let none, _) = try classify(.errorUnknownPlayer) else { Issue.record("null"); return }
        #expect(none == .null)
        guard case .result(_, let seconds, _) = try classify(.time) else { Issue.record("time"); return }
        #expect(seconds.doubleValue != nil)
        guard case .unknown = MAEnvelope.parse("{\"hello\":1}") else { Issue.record("unknown"); return }
        guard case .unknown = MAEnvelope.parse("not json") else { Issue.record("garbage"); return }
    }

    /// Shapes from the API page, unrecorded until #0076.
    @Test func eventsDecodeLenientlyFromTheDocumentedShapeUnrecordedUntil0076() {
        guard case .event(let updated) = MAEnvelope.parse("{\"event\":\"player_updated\",\"object_id\":\"x\",\"data\":{\"player_id\":\"x\"}}") else {
            Issue.record("player_updated")
            return
        }
        #expect(updated.event == "player_updated")
        #expect(updated.objectID == "x")
        #expect(updated.data["player_id"] == "x")
        guard case .event(let tasks) = MAEnvelope.parse("{\"event\":\"tasks_updated\",\"data\":[]}") else {
            Issue.record("tasks_updated")
            return
        }
        #expect(tasks.objectID == nil)
        #expect(tasks.data == .array([]))
        guard case .event(let bare) = MAEnvelope.parse("{\"event\":\"application_shutdown\"}") else {
            Issue.record("application_shutdown")
            return
        }
        #expect(bare.data == .null)
        #expect(MAServerEvent.knownNames.contains("queue_time_updated"))
    }
}

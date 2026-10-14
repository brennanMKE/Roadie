import Foundation
import MusicAssistantKitStub
import Testing
@testable import MusicAssistantKit

struct MARequestEncodingTests {
    private func expect(_ request: MARequest, matches fixture: MAFixture, sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(request.command == fixture.command, sourceLocation: sourceLocation)
        #expect(MAJSON.object(request.args) == fixture.args, "\(fixture.rawValue) args", sourceLocation: sourceLocation)
    }

    @Test func libraryRequestsUseTheRecordedArgNames() {
        expect(.libraryItems(.artist, limit: 3, offset: 0, orderBy: "sort_name", albumArtistsOnly: true), matches: .artistsPage)
        expect(.libraryItems(.artist, limit: 3, offset: 474, albumArtistsOnly: true), matches: .artistsLastPage)
        expect(.libraryItems(.album, limit: 3, offset: 0), matches: .albumsPage)
        expect(.libraryItems(.track, limit: 3, offset: 0), matches: .tracksPage)
        expect(.libraryItems(.playlist, limit: 3, offset: 0), matches: .playlistsPage)
        expect(.count(.artist), matches: .artistsCount)
        expect(.count(.album), matches: .albumsCount)
        expect(.count(.track), matches: .tracksCount)
        expect(.count(.playlist), matches: .playlistsCount)
        expect(.albumTracks(itemID: "27", provider: "library", inLibraryOnly: true), matches: .albumTracks)
        expect(.artistAlbums(itemID: "432", provider: "library"), matches: .artistAlbums)
        expect(.playlistTracks(itemID: "4", provider: "library"), matches: .playlistTracks)
        expect(.player(id: "ap223aed81fe30"), matches: .playerGet)
        expect(.queue(id: "ap223aed81fe30"), matches: .playerQueueGet)
        expect(.activeQueue(playerID: "ap223aed81fe30"), matches: .playerQueueActive)
        expect(.playersAll(), matches: .playersAll)
        expect(.queuesAll(), matches: .playerQueuesAll)
        expect(.time(), matches: .time)
        expect(.itemByURI("library://album/27"), matches: .itemByURI)
        expect(.get(.album, itemID: "27", provider: "library"), matches: .albumGet)
        expect(.providers(type: "music"), matches: .providers)
        #expect(MARequest.playlistTracks(itemID: "4", provider: "library").timeout == .seconds(60))
    }

    @Test func searchUsesTheRecordedArgNames() throws {
        let request = MARequest.search(query: "008-tapbots", mediaTypes: [.artist, .album, .track], limit: 3)
        #expect(request.command == "music/search")
        #expect(request.args["search_query"] == "008-tapbots")
        #expect(request.args["media_types"] == ["artist", "album", "track"])
        #expect(request.args["limit"] == 3)
        #expect(request.args["providers"] == ["library"])
        let recorded = try #require(MAFixture.search.args?.objectValue)
        #expect(Set(request.args.keys) == Set(recorded.keys))
    }

    @Test func queueItemsUseTheDocumentedArgNames() {
        let request = MARequest.queueItems(id: "q", limit: 50, offset: 100)
        #expect(request.command == "player_queues/items")
        #expect(MAJSON.object(request.args) == ["queue_id": "q", "limit": 50, "offset": 100])
    }

    @Test func playerCommandsUseTheDocumentedArgNames() {
        let play = MARequest.playerCommand(.playPause, playerID: "p")
        #expect(play.command == "players/cmd/play_pause")
        #expect(MAJSON.object(play.args) == ["player_id": "p"])
        #expect(MARequest.playerCommand(.next, playerID: "p").command == "players/cmd/next")
        #expect(MARequest.playerCommand(.previous, playerID: "p").command == "players/cmd/previous")
        let seek = MARequest.seek(playerID: "p", position: 12)
        #expect(seek.command == "players/cmd/seek")
        #expect(MAJSON.object(seek.args) == ["player_id": "p", "position": 12])
        #expect(seek.encodedFrame(messageID: "7").contains("\"position\":12,") || seek.encodedFrame(messageID: "7").contains("\"position\":12}"))
        #expect(MAJSON.object(MARequest.volumeSet(playerID: "p", level: 57).args) == ["player_id": "p", "volume_level": 57])
        #expect(MAJSON.object(MARequest.volumeMute(playerID: "p", muted: true).args) == ["player_id": "p", "muted": true])
        #expect(MAJSON.object(MARequest.shuffle(playerID: "p", enabled: true).args) == ["player_id": "p", "shuffle_enabled": true])
        let repeatAll = MARequest.repeat(playerID: "p", mode: .all)
        #expect(repeatAll.command == "players/cmd/repeat")
        #expect(MAJSON.object(repeatAll.args) == ["player_id": "p", "repeat_mode": "all"])
    }

    @Test func playMediaEncodesOptionsAndStartItem() {
        let replace = MARequest.playMedia(
            queueID: "q", media: ["library://album/27"], option: .replace, startItem: "library://track/132")
        #expect(replace.command == "player_queues/play_media")
        #expect(
            MAJSON.object(replace.args)
                == ["queue_id": "q", "media": ["library://album/27"], "option": "replace", "start_item": "library://track/132"])
        let add = MARequest.playMedia(queueID: "q", media: ["library://track/1"], option: .add)
        #expect(add.args["start_item"] == nil)
        #expect(add.args["option"] == "add")
        #expect(MARequest.playMedia(queueID: "q", media: [], option: .replaceNext).args["option"] == "replace_next")
    }

    @Test func authRequestPrintsRedacted() {
        let request = MARequest.auth(token: testToken)
        #expect(String(describing: request) == "auth(redacted)")
        let frame = request.encodedFrame(messageID: "1")
        #expect(frame.components(separatedBy: "ma-UNIT-TEST-TOKEN").count == 2)
        #expect(String(describing: MARequest.time()) == "time")
    }

    @Test func kwargsIsNeverSent() {
        let requests: [MARequest] = [
            .libraryItems(.album, limit: 1, offset: 0), .count(.track), .albumTracks(itemID: "1", provider: "library"),
            .search(query: "x", mediaTypes: [.track], limit: 1), .playersAll(), .queuesAll(),
            .playerCommand(.play, playerID: "p"), .playMedia(queueID: "q", media: [], option: .play),
            .auth(token: testToken),
        ]
        for request in requests { #expect(request.args["kwargs"] == nil) }
    }
}

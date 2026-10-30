import Foundation
import LibraryBrowser
import MusicBackendKit
import XCTest

@testable import Roadie

/// The pure parts of the Library window's views (#0215): what a selection plays, headings, symbols, footers and bars.
@MainActor
final class LibraryViewLogicTests: XCTestCase {
    private func track(_ id: String, album: String? = nil) -> LibraryTrack {
        LibraryTrack(id: MediaID(.track, id), title: "Track \(id)", artistName: "Artist", albumID: album.map { MediaID(.album, $0) })
    }

    func testDiscoverPlayableSkipsMappings() {
        let album = LibraryAlbum(id: MediaID(.album, "a1"), title: "Album")
        let song = track("t1")
        let items: [RecommendationItem] = [
            .track(song),
            .other(uri: "podcast://p1", kind: nil, name: "A podcast", subtitle: nil, artwork: nil),
            .album(album),
            .other(uri: "library://radio/r1", kind: .radio, name: "Station", subtitle: nil, artwork: nil),
        ]
        let all = Set(items.map(\.id))
        // Display order, the kind-less mapping skipped, a kinded mapping kept.
        XCTAssertEqual(
            DiscoverRowView.playable(all, in: items),
            [song.id, album.id, MediaID(.radio, "library://radio/r1")])
        XCTAssertEqual(DiscoverRowView.playable(["podcast://p1"], in: items), [])
        XCTAssertEqual(DiscoverRowView.playable([], in: items), [])

        XCTAssertNil(DiscoverRowView.request([], mode: .next))
        XCTAssertEqual(
            DiscoverRowView.request([song.id], mode: .append), PlayRequest(items: [song.id], mode: .append))

        let symbols: [MediaKind?: String] = [
            .artist: "music.mic", .album: "square.stack", .track: "music.note", .playlist: "music.note.list",
            .radio: "antenna.radiowaves.left.and.right", nil: "questionmark.square.dashed",
        ]
        for kind in MediaKind.allCases.map(Optional.some) + [nil] {
            XCTAssertEqual(DiscoverItemRow.symbol(kind), symbols[kind], "\(String(describing: kind))")
        }
    }

    func testFavoriteKindTitlesAndSymbols() {
        let expected: [FavoriteKind: (String, String)] = [
            .tracks: ("Tracks", "music.note"), .albums: ("Albums", "square.stack"), .artists: ("Artists", "music.mic"),
            .playlists: ("Playlists", "music.note.list"), .radios: ("Radio", "antenna.radiowaves.left.and.right"),
        ]
        XCTAssertEqual(Set(FavoriteKind.allCases), Set(expected.keys))
        for kind in FavoriteKind.allCases {
            XCTAssertEqual(FavoriteKindsView.title(kind), expected[kind]?.0)
            XCTAssertEqual(FavoriteKindsView.symbol(kind), expected[kind]?.1)
        }
        // A favourite kind and its Discover kind share a symbol.
        XCTAssertEqual(FavoriteKindsView.symbol(.albums), DiscoverItemRow.symbol(.album))
    }

    func testTrackListHeading() {
        let album = LibraryAlbum(id: MediaID(.album, "a1"), title: "Blue", artistName: "Joni")
        let playlist = LibraryPlaylist(id: MediaID(.playlist, "p1"), name: "Mix")
        XCTAssertEqual(TrackListView.heading(album: album, playlist: playlist), "Blue", "the album wins")
        XCTAssertEqual(TrackListView.heading(album: nil, playlist: playlist), "Mix")
        XCTAssertEqual(TrackListView.heading(album: nil, playlist: nil), "")
        XCTAssertEqual(TrackListView.albumArtist(album: album), "Joni")
        XCTAssertNil(TrackListView.albumArtist(album: nil))
        XCTAssertNil(TrackListView.openPlaylist(album: album, playlist: playlist), "an album's tracks take no drops")
        XCTAssertEqual(TrackListView.openPlaylist(album: nil, playlist: playlist), playlist)
        XCTAssertNil(TrackListView.openPlaylist(album: nil, playlist: nil))

        XCTAssertEqual(
            PlaylistTracksView.confirmTitle(count: 12, playlist: "Mix"), "Remove 12 tracks from \u{201C}Mix\u{201D}?")
        XCTAssertEqual(PlaylistTracksView.confirmThreshold, 10)
        XCTAssertEqual(PlaylistEditingModifier.deleteTitle(playlist), "Delete \u{201C}Mix\u{201D}?")
        XCTAssertEqual(PlaylistEditingModifier.deleteTitle(nil), "Delete \u{201C}\u{201D}?")
    }

    func testRadioAddParsesURL() {
        XCTAssertTrue(AddRadioSheet.canAdd(url: " https://radio.example/stream ", adding: false))
        XCTAssertTrue(AddRadioSheet.canAdd(url: "http://radio.example", adding: false))
        XCTAssertFalse(AddRadioSheet.canAdd(url: "https://radio.example/stream", adding: true), "one add at a time")
        XCTAssertFalse(AddRadioSheet.canAdd(url: "ftp://radio.example", adding: false))
        XCTAssertFalse(AddRadioSheet.canAdd(url: "radio.example", adding: false))
        XCTAssertFalse(AddRadioSheet.canAdd(url: "", adding: false))

        let one = LibraryRadio(id: MediaID(.radio, "r1"), name: "One")
        let two = LibraryRadio(id: MediaID(.radio, "r2"), name: "Two")
        // The first selected in list order, alone.
        XCTAssertEqual(
            RadioListView.request([two.id, one.id], in: [one, two]), PlayRequest(items: [one.id], mode: .replace()))
        XCTAssertEqual(RadioListView.request([two.id], in: [one, two]), PlayRequest(items: [two.id], mode: .replace()))
        XCTAssertNil(RadioListView.request([MediaID(.radio, "gone")], in: [one, two]))
        XCTAssertNil(RadioListView.request([], in: [one, two]))
    }

    func testOutputNameFallsBack() {
        let kitchen = OutputDevice(id: OutputDevice.ID(rawValue: "kitchen"), name: "Kitchen", kind: .remote)
        let den = OutputDevice(
            id: OutputDevice.ID(rawValue: "den"), name: "Den", kind: .remote, groupableWith: [OutputDevice.thisMacID])
        let attic = OutputDevice(id: OutputDevice.ID(rawValue: "attic"), name: "Attic", kind: .remote, isAvailable: false)
        let party = OutputDevice(id: OutputDevice.ID(rawValue: "party"), name: "Party", kind: .remote, isGroup: true)
        let devices = [kitchen, den, attic, party]

        XCTAssertEqual(OutputPickerView.name(of: kitchen.id, devices: devices), "Kitchen")
        XCTAssertEqual(OutputPickerView.name(of: OutputDevice.thisMacID, devices: []), "This Mac")
        XCTAssertEqual(OutputPickerView.name(of: OutputDevice.ID(rawValue: "gone"), devices: devices), "Speaker")

        // Kitchen leads, This Mac is a member.
        let grouped = OutputSelection(leader: kitchen.id, members: [OutputDevice.thisMacID])
        XCTAssertEqual(
            OutputPickerView.rowState(kitchen, selection: grouped),
            .init(isChecked: true, isDisabled: false, showsLeader: true, onlyDisabled: false))
        XCTAssertEqual(
            OutputPickerView.rowState(.thisMac, selection: grouped),
            .init(isChecked: true, isDisabled: false, showsLeader: false, onlyDisabled: false))
        // Den syncs only with This Mac, so it can't join Kitchen.
        XCTAssertEqual(
            OutputPickerView.rowState(den, selection: grouped),
            .init(isChecked: false, isDisabled: true, showsLeader: false, onlyDisabled: false))
        XCTAssertEqual(
            OutputPickerView.rowState(den, selection: .thisMac),
            .init(isChecked: false, isDisabled: false, showsLeader: false, onlyDisabled: false))
        XCTAssertEqual(
            OutputPickerView.rowState(attic, selection: .thisMac),
            .init(isChecked: false, isDisabled: true, showsLeader: false, onlyDisabled: true))
        // A lone leader has no caption.
        XCTAssertFalse(OutputPickerView.rowState(.thisMac, selection: .thisMac).showsLeader)

        XCTAssertTrue(OutputPickerView.groupIsChecked(party, selection: OutputSelection(leader: party.id)))
        XCTAssertFalse(OutputPickerView.groupIsChecked(party, selection: grouped))
    }

    func testPlaylistEditBarContent() {
        XCTAssertEqual(PlaylistEditBar.content(pending: "Removing 2 tracks…", error: "Old"), .pending("Removing 2 tracks…"))
        XCTAssertEqual(PlaylistEditBar.content(pending: nil, error: "Refused"), .error("Refused"))
        XCTAssertEqual(PlaylistEditBar.content(pending: nil, error: nil), .nothing)
    }

    func testPagedFooterContent() async throws {
        XCTAssertEqual(PagedListFooter(isLoadingMore: true, loadMoreError: "x", countLabel: "1 of 2"), .loading)
        XCTAssertEqual(PagedListFooter(isLoadingMore: false, loadMoreError: "Lost", countLabel: "1 of 2"), .error("Lost"))
        XCTAssertEqual(PagedListFooter(isLoadingMore: false, loadMoreError: nil, countLabel: "1 of 2"), .count("1 of 2"))
        XCTAssertEqual(PagedListFooter(isLoadingMore: false, loadMoreError: nil, countLabel: nil), .nothing)

        // From a real list: the first page loaded with a known total shows the count.
        let ids = (0..<3).map { MediaID(.radio, "r\($0)") }
        let list = PagedList<LibraryRadio>(loader: { _ in
            Page(items: ids.prefix(2).map { LibraryRadio(id: $0, name: $0.rawValue) }, offset: 0, total: 3, nextOffset: nil)
        })
        list.reload()
        let deadline = ContinuousClock.now + .seconds(5)
        while list.phase != .loaded, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(list.phase, .loaded)
        XCTAssertEqual(PagedListFooter(list), .count("2 of 3"))
    }

    func testSearchResultSections() {
        let artist = LibraryArtist(id: MediaID(.artist, "ar1"), name: "Artist")
        let album = LibraryAlbum(id: MediaID(.album, "a1"), title: "Album")
        let song = track("t1")
        XCTAssertEqual(
            SearchResultsView.sections(SearchResults(artists: [artist], albums: [album], tracks: [song])),
            [.artists, .albums, .tracks])
        XCTAssertEqual(SearchResultsView.sections(SearchResults(artists: [artist], tracks: [song])), [.artists, .tracks])
        XCTAssertEqual(SearchResultsView.sections(SearchResults(albums: [album])), [.albums])
        XCTAssertEqual(SearchResultsView.sections(.empty), [])
        XCTAssertEqual(SearchResultsView.ResultSection.allCases.map(\.rawValue), ["Artists", "Albums", "Tracks"])
    }

    func testLibraryActionsBuildRequests() {
        let rows = [track("t1", album: "a1"), track("t2", album: "a1"), track("t3", album: "a1")]
        let album = MediaID(.album, "a1")
        let second: Set<MediaID> = [rows[1].id]
        let two: Set<MediaID> = [rows[2].id, rows[0].id]

        // One track in an album plays the album from it; several play just those, in display order.
        XCTAssertEqual(
            LibraryPlayAction.play.request(second, in: rows, album: album),
            PlayRequest(items: rows.map(\.id), mode: .replace(startIndex: 1)))
        XCTAssertEqual(
            LibraryPlayAction.play.request(second, in: rows, album: nil), PlayRequest(items: [rows[1].id], mode: .replace()))
        XCTAssertEqual(
            LibraryPlayAction.play.request(two, in: rows, album: album),
            PlayRequest(items: [rows[0].id, rows[2].id], mode: .replace()))
        XCTAssertEqual(
            LibraryPlayAction.next.request(two, in: rows, album: album), PlayRequest(items: [rows[0].id, rows[2].id], mode: .next))
        XCTAssertEqual(
            LibraryPlayAction.append.request(second, in: rows, album: album), PlayRequest(items: [rows[1].id], mode: .append))
        for action in LibraryPlayAction.allCases {
            XCTAssertNil(action.request([], in: rows, album: album), "\(action): nothing selected")
            XCTAssertNil(action.request([MediaID(.track, "gone")], in: rows, album: album), "\(action): not in rows")
        }

        // Containers: the album, artist or playlist id itself.
        let playlist = MediaID(.playlist, "p1")
        XCTAssertEqual(LibraryPlayAction.play.request(container: playlist), PlayRequest(items: [playlist], mode: .replace()))
        XCTAssertEqual(LibraryPlayAction.next.request(container: playlist), PlayRequest(items: [playlist], mode: .next))
        XCTAssertEqual(LibraryPlayAction.append.request(container: album), PlayRequest(items: [album], mode: .append))
    }
}

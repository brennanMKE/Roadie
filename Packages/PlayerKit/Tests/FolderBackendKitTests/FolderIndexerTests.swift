import AudioCore
import Foundation
import MusicBackendKit
import Testing
@testable import FolderBackendKit

private func build(_ root: URL, previous: FolderIndex? = nil, indexer: FolderIndexer = FolderIndexer()) async throws -> FolderIndex {
    try await indexer.build(root: root, previous: previous)
}

private func tracks(of album: String, in index: FolderIndex) -> [LibraryTrack] {
    index.tracks.map(\.library).filter { $0.albumID == albumID(album) }
}

@Suite struct FolderIndexerTests {
    @Test func artistsComeFromTopLevelFoldersAndAlbumsFromTheirSubfolders() async throws {
        let root = makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        try makeLibrary(in: root)
        let index = try await build(root)

        #expect(index.artists.map(\.name) == ["10,000 Maniacs", "The Beatles", "Unknown Artist"])
        #expect(index.artists.map(\.id) == [artistID("10,000 Maniacs"), artistID("The Beatles"), artistID(".")])
        #expect(index.artists[1].sortName == "Beatles")
        let eden = try #require(index.albums.first { $0.id == albumID("10,000 Maniacs/Our Time in Eden (1992)") })
        #expect(eden.title == "Our Time in Eden")
        #expect(eden.year == 1992)
        #expect(eden.trackCount == 2)
        #expect(eden.artistName == "10,000 Maniacs")
        #expect(!index.artists.contains { $0.name.hasPrefix("Empty") })
        #expect(index.summary.artists == 3)
        #expect(index.summary.albums == 4)
        #expect(index.summary.tracks == 7)
        #expect(index.skipped.count == 2)
        #expect(index.summary.text == "3 artists, 4 albums, 7 tracks, 2 files skipped")
    }

    @Test func trackNumbersAndTitlesComeFromFilenamesWhenUntagged() async throws {
        let root = makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        try makeLibrary(in: root)
        let index = try await build(root)
        let eden = tracks(of: "10,000 Maniacs/Our Time in Eden (1992)", in: index)

        #expect(eden.map(\.title) == ["Noah's Dove", "These Are Days"])
        #expect(eden.map(\.trackNumber) == [1, 2])
        #expect(eden.allSatisfy { $0.discNumber == nil })
        #expect(eden.allSatisfy { $0.artistName == "10,000 Maniacs" })
        let first = try #require(eden.first)
        #expect(abs((first.duration ?? 0) - 0.2) < 0.05)
        #expect(first.sampleRate == 44_100)
        #expect(first.channels == 2)
        #expect(first.bitrate != nil)
    }

    @Test func discFoldersSetTheDiscNumberAndKeepOneAlbum() async throws {
        let root = makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        try makeLibrary(in: root)
        let index = try await build(root)

        #expect(index.albums.filter { $0.title == "The White Album" }.count == 1)
        let white = tracks(of: "The Beatles/The White Album", in: index)
        #expect(white.map(\.title) == ["Back in the U.S.S.R.", "Dear Prudence", "Birthday"])
        #expect(white.map { $0.discNumber } == [1, 1, 2])
        #expect(white.map { $0.trackNumber } == [1, 2, 1])
        #expect(white[0].id == trackID("The Beatles/The White Album/Disc 1/01 Back in the U.S.S.R..wav"))
    }

    @Test func looseTracksUnderAnArtistFormASinglesAlbum() async throws {
        let root = makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        try makeLibrary(in: root)
        let index = try await build(root)

        let singles = try #require(index.albums.first { $0.id == albumID("10,000 Maniacs") })
        #expect(singles.title == "Singles")
        let loose = tracks(of: "10,000 Maniacs", in: index)
        #expect(loose.map(\.title) == ["Loose Single"])
        #expect(loose[0].trackNumber == nil)
        let maniacs = index.albums.filter { $0.artistID == artistID("10,000 Maniacs") }
        #expect(maniacs.map(\.title) == ["Our Time in Eden", "Singles"])
    }

    @Test func rootLevelTracksGoUnderUnknownArtist() async throws {
        let root = makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        try makeLibrary(in: root)
        let index = try await build(root)

        let unknown = try #require(index.albums.first { $0.id == albumID(".") })
        #expect(unknown.title == "Unknown Album")
        #expect(unknown.artistID == artistID("."))
        #expect(tracks(of: ".", in: index).map(\.title) == ["Loose Root"])
        #expect(index.artists.last?.id == artistID("."))
        #expect(index.albums.last?.id == albumID("."))
    }

    @Test func unsupportedFilesAreReportedAndSidecarsIgnored() async throws {
        let root = makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        try makeLibrary(in: root)
        let index = try await build(root)

        #expect(Set(index.skipped.map(\.relativePath)) == ["The Beatles/junk.mp3", "The Beatles/weird.xyz"])
        let byPath = Dictionary(uniqueKeysWithValues: index.skipped.map { ($0.relativePath, $0.reason) })
        #expect(byPath["The Beatles/weird.xyz"] == "not an audio file")
        #expect(byPath["The Beatles/junk.mp3"]?.isEmpty == false)
        #expect(!index.tracks.contains { $0.relativePath.contains("secret") })
    }

    @Test func artworkPrefersCoverThenFolder() async throws {
        let root = makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        try makeLibrary(in: root)
        let index = try await build(root)

        func album(_ path: String) throws -> LibraryAlbum { try #require(index.albums.first { $0.id == albumID(path) }) }
        #expect(try album("10,000 Maniacs/Our Time in Eden (1992)").artwork
            == ArtworkRef(rawValue: "file:10,000 Maniacs/Our Time in Eden (1992)/cover.jpg"))
        #expect(try album("The Beatles/The White Album").artwork
            == ArtworkRef(rawValue: "file:The Beatles/The White Album/folder.jpg"))
        #expect(try album("10,000 Maniacs").artwork == nil)
        #expect(try album(".").artwork == nil)
        #expect(index.artists[0].artwork == ArtworkRef(rawValue: "file:10,000 Maniacs/Our Time in Eden (1992)/cover.jpg"))
        #expect(index.artists[2].artwork == nil)
        // The tracks carry their album's art.
        #expect(index.tracks[0].library.artwork == index.albums[0].artwork)
    }

    @Test func yearPatternsInAlbumFolderNames() async throws {
        let root = makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        for album in ["1999 - Nine", "Ten (2010)", "Eleven (not a year)", "2200 - Future"] {
            try writeWAV(to: root.appending(path: "A/\(album)/01 Song.wav"))
        }
        let index = try await build(root)
        let byTitle = Dictionary(uniqueKeysWithValues: index.albums.map { ($0.title, $0.year) })
        #expect(byTitle["Nine"] == 1999)
        #expect(byTitle["Ten"] == 2010)
        #expect(byTitle["Eleven (not a year)"] == .some(nil))
        #expect(byTitle["2200 - Future"] == .some(nil))
        #expect(index.albums.count == 4)
        // Dated albums first, in year order.
        #expect(index.albums.prefix(2).map(\.title) == ["Nine", "Ten"])
    }

    @Test func mediaIDsAreStableAcrossRootsAndNFCNormalized() async throws {
        let root = makeTempDir()
        let copy = makeTempDir()
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: copy)
        }
        try makeLibrary(in: root)
        let moved = copy.appending(path: "moved")
        try FileManager.default.copyItem(at: root, to: moved)
        let first = try await build(root)
        let second = try await build(moved)
        #expect(first.artists == second.artists)
        #expect(first.albums == second.albums)
        #expect(first.tracks.map(\.library) == second.tracks.map(\.library))

        let decomposed = root.appending(path: "Caf\u{65}\u{301}/Album/01 Song.wav")
        try writeWAV(to: decomposed)
        let index = try await build(root)
        let cafe = try #require(index.artists.first { $0.id == artistID("Caf\u{E9}") })
        #expect(cafe.id.rawValue == "Caf\u{E9}")
        let track = try #require(index.tracks.first { $0.library.artistID == cafe.id })
        // The path keeps the on-disk spelling, and opening the file through it works.
        #expect(FileManager.default.fileExists(atPath: track.url(root: root.standardizedFileURL.resolvingSymlinksInPath()).path))
        #expect(track.library.id.rawValue == "Caf\u{E9}/Album/01 Song.wav")
    }

    @Test func rescanReusesUnchangedEntriesAndRereadsChangedOnes() async throws {
        let root = makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        try makeLibrary(in: root)
        let counter = CountingLoader()
        let indexer = countingIndexer(counter)

        let first = try await build(root, indexer: indexer)
        // Seven tracks plus junk.mp3, which `AVAudioFile` rejects.
        #expect(await counter.count == 8)

        let second = try await build(root, previous: first, indexer: indexer)
        #expect(await counter.count == 8)
        #expect(second.artists == first.artists)
        #expect(second.albums == first.albums)
        #expect(second.tracks == first.tracks)
        #expect(second.skipped == first.skipped)

        let eden = root.appending(path: "10,000 Maniacs/Our Time in Eden (1992)")
        try writeWAV(to: eden.appending(path: "02 These Are Days.wav"), seconds: 0.5)
        try writeWAV(to: eden.appending(path: "03 Candy.wav"))
        let third = try await build(root, previous: second, indexer: indexer)
        #expect(await counter.count == 10)
        let days = try #require(third.tracks.first { $0.library.title == "These Are Days" })
        #expect(abs((days.library.duration ?? 0) - 0.5) < 0.05)
        let edenAlbum = try #require(third.albums.first { $0.title == "Our Time in Eden" })
        #expect(edenAlbum.trackCount == 3)

        try FileManager.default.removeItem(at: root.appending(path: "Loose Root.wav"))
        let fourth = try await build(root, previous: third, indexer: indexer)
        #expect(!fourth.artists.contains { $0.id == artistID(".") })
        #expect(await counter.count == 10)
    }

    @Test func indexingRunsOffTheMainActor() async throws {
        let root = makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        try makeLibrary(in: root)
        let counter = CountingLoader()
        _ = try await build(root, indexer: countingIndexer(counter))
        #expect(await counter.count == 8)
        #expect(await counter.mainThreadCalls == 0)
    }

    @Test func cancellationStopsAScan() async throws {
        let root = makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        try makeLibrary(in: root)
        let started = CountingLoader()
        let indexer = FolderIndexer(loader: { url in
            await started.record(url, onMain: false)
            try await Task.sleep(for: .seconds(60))
            throw CocoaError(.fileReadUnknown)
        })
        let begin = Date()
        let task = Task { try await indexer.build(root: root, previous: nil) }
        while await started.count == 0 { try await Task.sleep(for: .milliseconds(5)) }
        task.cancel()
        let result = await task.result
        guard case .failure(let error) = result else {
            Issue.record("the cancelled scan returned an index")
            return
        }
        #expect(error is CancellationError)
        #expect(Date().timeIntervalSince(begin) < 10)
    }

    @Test func trackNumberTextParses() {
        #expect(FolderTrackNumbers.parse("3") == 3)
        #expect(FolderTrackNumbers.parse("3/12") == 3)
        #expect(FolderTrackNumbers.parse(" 07 ") == 7)
        #expect(FolderTrackNumbers.parse("x") == nil)
        #expect(FolderTrackNumbers.parse("0") == nil)
    }

    @Test func discFolderNamesParse() {
        #expect(FolderWalk.discNumber("Disc 1") == 1)
        #expect(FolderWalk.discNumber("disc02") == 2)
        #expect(FolderWalk.discNumber("CD 3") == 3)
        #expect(FolderWalk.discNumber("Disk 10") == 10)
        #expect(FolderWalk.discNumber("Discography") == nil)
        #expect(FolderWalk.discNumber("Bonus") == nil)
    }

    @Test func anUnreadableRootThrows() async {
        let missing = makeTempDir().appending(path: "nope")
        await #expect(throws: (any Error).self) { _ = try await FolderIndexer().build(root: missing, previous: nil) }
    }
}

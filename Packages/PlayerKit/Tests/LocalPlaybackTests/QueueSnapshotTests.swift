import AudioCore
import Foundation
import MusicBackendKit
import Testing
@testable import LocalPlayback

private func tempFile() -> (dir: URL, file: URL) {
    let dir = FileManager.default.temporaryDirectory.appending(path: "queue-\(UUID().uuidString)", directoryHint: .isDirectory)
    return (dir, dir.appending(path: "queue.json"))
}

private func sampleSnapshot() -> QueueSnapshot {
    let a = LocalQueueItem(
        track: Track(title: "A", artist: "Artist", duration: 10, source: .file(URL(fileURLWithPath: "/Volumes/Music/a.mp3"))),
        id: nil)
    let b = LocalQueueItem(
        track: Track(
            title: "B", artist: "Artist", album: "Album", duration: 241.3, bitrate: 320, sampleRate: 44100, channels: 2,
            source: .file(URL(fileURLWithPath: "/Volumes/Music/Artist/Album/01.mp3"))),
        id: MediaID(.track, "Artist/Album/01.mp3"))
    return QueueSnapshot(items: [a, b], currentIndex: 1, repeatMode: .all, isShuffled: true)
}

@MainActor
@Suite struct QueueSnapshotTests {
    @Test func snapshotRoundTripsThroughJSON() throws {
        let (dir, file) = tempFile()
        defer { try? FileManager.default.removeItem(at: dir) }
        let snapshot = sampleSnapshot()
        let store = QueueStore(fileURL: file)
        try store.save(snapshot)
        let loaded = try #require(store.load())
        #expect(loaded == snapshot)
        #expect(loaded.items.map(\.track.id) == snapshot.items.map(\.track.id))
        #expect(loaded.items[0].track.album == nil)
        #expect(loaded.items[0].track.bitrate == nil)
        #expect(loaded.items[0].id == nil)
    }

    @Test func encodedKeysAreTheDocumentedSet() throws {
        let (dir, file) = tempFile()
        defer { try? FileManager.default.removeItem(at: dir) }
        try QueueStore(fileURL: file).save(sampleSnapshot())
        let data = try Data(contentsOf: file)
        let root = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(Set(root.keys) == ["version", "items", "currentIndex", "repeat", "shuffle", "upNext"])
        #expect(root["version"] as? Int == 1)
        let items = try #require(root["items"] as? [[String: Any]])
        let allowed: Set<String> = ["id", "title", "artist", "album", "duration", "bitrate", "sampleRate", "channels", "source", "mediaID"]
        for item in items { #expect(Set(item.keys).isSubset(of: allowed)) }
        let fileSource = try #require(items[0]["source"] as? [String: Any])
        #expect(Set(fileSource.keys) == ["kind", "path"])
        let text = String(decoding: data, as: UTF8.self)
        for forbidden in ["token", "http", "Bearer"] { #expect(!text.contains(forbidden)) }
    }

    @Test func storeLoadsNilForMissingCorruptOrNewerFiles() throws {
        let (dir, file) = tempFile()
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = QueueStore(fileURL: file)
        #expect(store.load() == nil)
        let bodies = [
            "{",
            #"{"version":2,"items":[],"repeat":"off","shuffle":false}"#,
        ]
        for body in bodies {
            try body.write(to: file, atomically: true, encoding: .utf8)
            #expect(store.load() == nil)
            #expect(FileManager.default.fileExists(atPath: file.path))
            #expect(try String(contentsOf: file, encoding: .utf8) == body)
        }
    }

    @Test func storeSavesAtomicallyIntoANewDirectory() throws {
        let (dir, file) = tempFile()
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(!FileManager.default.fileExists(atPath: dir.path))
        let store = QueueStore(fileURL: file)
        let snapshot = sampleSnapshot()
        try store.save(snapshot)
        #expect(store.load() == snapshot)
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path) == ["queue.json"])
    }

    @Test func duplicateOrMissingIdsGetFreshOnes() throws {
        let (dir, file) = tempFile()
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let id = UUID().uuidString
        let item = #"{"id":"\#(id)","title":"x","artist":"","duration":1,"source":{"kind":"file","path":"/x.wav"}}"#
        let noID = #"{"title":"y","artist":"","duration":1,"source":{"kind":"file","path":"/y.wav"}}"#
        try #"{"version":1,"repeat":"off","shuffle":false,"items":[\#(item),\#(item),\#(noID)]}"#
            .write(to: file, atomically: true, encoding: .utf8)
        let loaded = try #require(QueueStore(fileURL: file).load())
        #expect(loaded.items.count == 3)
        #expect(Set(loaded.items.map(\.track.id)).count == 3)
    }

    @Test func itemsOfRemovedOrUnknownKindsAreDroppedAndTheCurrentIndexFollows() throws {
        let (dir, file) = tempFile()
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let ids = (0..<5).map { _ in UUID() }
        func item(_ i: Int, _ title: String, _ source: String) -> String {
            #"{"id":"\#(ids[i].uuidString)","title":"\#(title)","artist":"","duration":1,"source":\#(source)}"#
        }
        func fileSource(_ name: String) -> String { #"{"kind":"file","path":"/m/\#(name).wav"}"# }
        let plex = #"{"kind":"plex","partKey":"/library/parts/1/f.m4a","cacheKey":"k","size":10}"#
        let items = [
            item(0, "A", fileSource("a")), item(1, "B", plex), item(2, "C", fileSource("c")),
            item(3, "D", #"{"kind":"stream","url":"x"}"#), item(4, "E", fileSource("e")),
        ].joined(separator: ",")
        let store = QueueStore(fileURL: file)
        for (current, expected) in [(2, 1), (1, nil), (4, 2)] as [(Int, Int?)] {
            let body = #"{"version":1,"currentIndex":\#(current),"repeat":"off","shuffle":false,"items":[\#(items)]}"#
            try body.write(to: file, atomically: true, encoding: .utf8)
            let loaded = try #require(store.loadQueue())
            #expect(loaded.snapshot.items.map(\.track.title) == ["A", "C", "E"])
            #expect(loaded.snapshot.items.map(\.track.id) == [ids[0], ids[2], ids[4]])
            #expect(loaded.snapshot.currentIndex == expected)
            #expect(loaded.droppedItems == 2)
            #expect(store.load() == store.loadQueue()?.snapshot)
            #expect(try String(contentsOf: file, encoding: .utf8) == body)
        }
        let onlyPlex = #"{"version":1,"currentIndex":0,"repeat":"off","shuffle":false,"items":[\#(item(1, "B", plex))]}"#
        try onlyPlex.write(to: file, atomically: true, encoding: .utf8)
        let loaded = try #require(store.loadQueue())
        #expect(loaded.snapshot.items.isEmpty)
        #expect(loaded.droppedItems == 1)
        #expect(!LocalPlayerOutput(player: Player()).restore(loaded.snapshot))
        #expect(try String(contentsOf: file, encoding: .utf8) == onlyPlex)
    }

    @Test func restoreFillsAnEmptyStoppedOutputWithoutStarting() throws {
        let player = Player()
        let output = LocalPlayerOutput(player: player)
        let snapshot = sampleSnapshot()
        #expect(output.restore(snapshot))
        #expect(player.queue.tracks.count == 2)
        #expect(player.queue.currentIndex == 1)
        #expect(player.state == .stopped)
        #expect(player.currentTime == 0)
        #expect(player.errorMessage == nil)
        #expect(player.repeatMode == .all)
        #expect(player.isShuffled)
        let now = output.snapshot()
        #expect(now.state == .stopped)
        #expect(now.item == MediaID(.track, "Artist/Album/01.mp3"))
        #expect(now.title == "B")
    }

    @Test func restoreIsRefusedWhenTheQueueIsNotEmptyOrNotStopped() async throws {
        let player = Player()
        let output = LocalPlayerOutput(player: player)
        player.enqueue([unreadableItem("X", id: nil).track])
        #expect(!output.restore(sampleSnapshot()))
        #expect(player.queue.tracks.count == 1)
        player.clearQueue()
        output.play([unreadableItem("U", id: nil)], mode: .replace(startIndex: 0))
        #expect(player.state == .loading)
        #expect(!output.restore(sampleSnapshot()))
        #expect(await waitFor { player.state == .stopped })
        player.clearQueue()
        let empty = QueueSnapshot(items: [], currentIndex: nil, repeatMode: .off, isShuffled: false)
        #expect(!output.restore(empty))
    }

    @Test func queueSnapshotAfterRestoreIsTheIdentity() {
        let output = LocalPlayerOutput(player: Player())
        var snapshot = sampleSnapshot()
        output.restore(snapshot)
        #expect(output.queueSnapshot() == snapshot)
        let queued = LocalPlayerOutput(player: Player())
        snapshot.upNext = [0]
        queued.restore(snapshot)
        #expect(queued.queueSnapshot() == snapshot)
    }

    @Test func upNextRoundTripsAsIndices() throws {
        let (dir, file) = tempFile()
        defer { try? FileManager.default.removeItem(at: dir) }
        var snapshot = sampleSnapshot()
        let extra = (0..<2).map { i in
            LocalQueueItem(track: Track(title: "X\(i)", artist: "", duration: 1, source: .file(URL(fileURLWithPath: "/m/x\(i).wav"))), id: nil)
        }
        snapshot.items += extra
        snapshot.upNext = [3, 0]
        let store = QueueStore(fileURL: file)
        try store.save(snapshot)
        let loaded = try #require(store.load())
        #expect(loaded.upNext == [3, 0])
        #expect(loaded == snapshot)
    }

    @Test func aFileWithoutUpNextLoadsWithAnEmptyList() throws {
        let (dir, file) = tempFile()
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let body = #"{"version":1,"currentIndex":0,"repeat":"off","shuffle":false,"items":[{"title":"A","artist":"","duration":1,"source":{"kind":"file","path":"/m/a.wav"}}]}"#
        try body.write(to: file, atomically: true, encoding: .utf8)
        let loaded = try #require(QueueStore(fileURL: file).load())
        #expect(loaded.items.count == 1)
        #expect(loaded.upNext == [])
    }

    private func writeFiveItems(upNext: String, to file: URL) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        func item(_ title: String, _ source: String) -> String {
            #"{"title":"\#(title)","artist":"","duration":1,"source":\#(source)}"#
        }
        func fileSource(_ name: String) -> String { #"{"kind":"file","path":"/m/\#(name).wav"}"# }
        let plex = #"{"kind":"plex","partKey":"/library/parts/1/f.m4a","cacheKey":"k","size":10}"#
        let items = [
            item("A", fileSource("a")), item("B", plex), item("C", fileSource("c")),
            item("D", fileSource("d")), item("E", fileSource("e")),
        ].joined(separator: ",")
        let body = #"{"version":1,"currentIndex":0,"repeat":"off","shuffle":false,"upNext":\#(upNext),"items":[\#(items)]}"#
        try body.write(to: file, atomically: true, encoding: .utf8)
    }

    @Test func upNextFollowsItemsWhenSomeAreDropped() throws {
        let (dir, file) = tempFile()
        defer { try? FileManager.default.removeItem(at: dir) }
        try writeFiveItems(upNext: "[4,1,2]", to: file)
        let loaded = try #require(QueueStore(fileURL: file).loadQueue())
        #expect(loaded.snapshot.items.map(\.track.title) == ["A", "C", "D", "E"])
        #expect(loaded.droppedItems == 1)
        #expect(loaded.snapshot.upNext == [3, 1])
    }

    @Test func upNextDropsDuplicatesAndOutOfRangeIndices() throws {
        let (dir, file) = tempFile()
        defer { try? FileManager.default.removeItem(at: dir) }
        try writeFiveItems(upNext: "[3,9,0,3,-1,5,0]", to: file)
        let loaded = try #require(QueueStore(fileURL: file).load())
        #expect(loaded.upNext == [2, 0])
    }

    @Test func restoreRebuildsUpNextByEntry() {
        let player = Player()
        let output = LocalPlayerOutput(player: player)
        let items = (0..<3).map { i in
            LocalQueueItem(track: Track(title: "T\(i)", artist: "", duration: 1, source: .file(URL(fileURLWithPath: "/m/t\(i).wav"))), id: nil)
        }
        let snapshot = QueueSnapshot(items: items, currentIndex: 1, repeatMode: .off, isShuffled: false, upNext: [2, 0])
        #expect(output.restore(snapshot))
        #expect(player.queue.upNext == [items[2].track.id, items[0].track.id])
        #expect(output.queueSnapshot().upNext == [2, 0])
    }

    @Test func anOutOfRangeCurrentIndexRestoresWithNoCurrentTrack() {
        let player = Player()
        let output = LocalPlayerOutput(player: player)
        var snapshot = sampleSnapshot()
        snapshot.currentIndex = 9
        #expect(output.restore(snapshot))
        #expect(player.queue.currentIndex == nil)
        #expect(player.queue.tracks.count == 2)
    }

    @Test func playingARestoredMissingFileSkipsThenStops() async {
        let player = Player()
        let output = LocalPlayerOutput(player: player)
        let items = [unreadableItem("one", id: nil), unreadableItem("two", id: nil)]
        var failures: [PlaybackFailure] = []
        player.addEventObserver { event in
            if case .failed(let failure) = event { failures.append(failure) }
        }
        #expect(output.restore(QueueSnapshot(items: items, currentIndex: 0, repeatMode: .off, isShuffled: false)))
        player.play()
        #expect(await waitFor { player.state == .stopped && player.errorMessage != nil && failures.count == 2 })
        #expect(player.queue.tracks.count == 2)
        #expect(failures.map(\.skipped) == [true, false])
    }
}

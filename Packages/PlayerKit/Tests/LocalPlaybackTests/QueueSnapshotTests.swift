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
    let c = LocalQueueItem(
        track: Track(
            title: "C", artist: "Artist", duration: 180,
            source: .plex(partKey: "/library/parts/5010/1791856627/file.m4a", cacheKey: "abcdef0123-5010-1791856627", size: 7_147_054)),
        id: MediaID(.track, "3001"))
    return QueueSnapshot(items: [a, b, c], currentIndex: 1, repeatMode: .all, isShuffled: true)
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
        #expect(Set(root.keys) == ["version", "items", "currentIndex", "repeat", "shuffle"])
        #expect(root["version"] as? Int == 1)
        let items = try #require(root["items"] as? [[String: Any]])
        let allowed: Set<String> = ["id", "title", "artist", "album", "duration", "bitrate", "sampleRate", "channels", "source", "mediaID"]
        for item in items { #expect(Set(item.keys).isSubset(of: allowed)) }
        let fileSource = try #require(items[0]["source"] as? [String: Any])
        #expect(Set(fileSource.keys) == ["kind", "path"])
        let plexSource = try #require(items[2]["source"] as? [String: Any])
        #expect(Set(plexSource.keys) == ["kind", "partKey", "cacheKey", "size"])
        let text = String(decoding: data, as: UTF8.self)
        for forbidden in ["token", "http", "X-Plex"] { #expect(!text.contains(forbidden)) }
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
            #"{"version":1,"items":[{"title":"x","artist":"","duration":1,"source":{"kind":"stream","url":"x"}}],"repeat":"off","shuffle":false}"#,
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

    @Test func restoreFillsAnEmptyStoppedOutputWithoutStarting() throws {
        let player = Player()
        let output = LocalPlayerOutput(player: player)
        let snapshot = sampleSnapshot()
        #expect(output.restore(snapshot))
        #expect(player.queue.tracks.count == 3)
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
        let snapshot = sampleSnapshot()
        output.restore(snapshot)
        #expect(output.queueSnapshot() == snapshot)
    }

    @Test func anOutOfRangeCurrentIndexRestoresWithNoCurrentTrack() {
        let player = Player()
        let output = LocalPlayerOutput(player: player)
        var snapshot = sampleSnapshot()
        snapshot.currentIndex = 9
        #expect(output.restore(snapshot))
        #expect(player.queue.currentIndex == nil)
        #expect(player.queue.tracks.count == 3)
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

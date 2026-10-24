import AudioCore
import Foundation
import MusicBackendKit
import Testing
@testable import LocalPlayback

@MainActor
@Suite struct QueueAutosaverTests {
    private func makeStore() -> (dir: URL, store: QueueStore) {
        let dir = FileManager.default.temporaryDirectory.appending(path: "autosave-\(UUID().uuidString)", directoryHint: .isDirectory)
        return (dir, QueueStore(fileURL: dir.appending(path: "queue.json")))
    }

    private func tracks(_ n: Int) -> [Track] { (0..<n).map { unreadableItem("t\($0)", id: nil).track } }

    @Test func autosaverWritesOnceAfterABurstOfChanges() async {
        let (dir, store) = makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let player = Player()
        let saver = QueueAutosaver(output: LocalPlayerOutput(player: player), store: store, delay: .milliseconds(50))
        saver.start()
        player.enqueue(tracks(1))
        player.enqueue(tracks(1))
        player.enqueue(tracks(1))
        #expect(await waitFor { store.load()?.items.count == 3 })
        try? await Task.sleep(for: .milliseconds(150))
        #expect(saver.saveCount == 1)
    }

    @Test func queuingARowSchedulesASave() async {
        let (dir, store) = makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let player = Player()
        let saver = QueueAutosaver(output: LocalPlayerOutput(player: player), store: store, delay: .milliseconds(50))
        saver.start()
        player.enqueue(tracks(3))
        #expect(await waitFor { store.load()?.items.count == 3 })
        let before = saver.saveCount
        player.toggleUpNext([player.queue.tracks[2].id])
        #expect(await waitFor { store.load()?.upNext == [2] })
        #expect(saver.saveCount > before)
    }

    @Test func autosaverFollowsLaterChanges() async {
        let (dir, store) = makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let player = Player()
        let saver = QueueAutosaver(output: LocalPlayerOutput(player: player), store: store, delay: .milliseconds(50))
        saver.start()
        player.enqueue(tracks(3))
        #expect(await waitFor { store.load()?.items.count == 3 })
        player.removeTrack(at: 0)
        #expect(await waitFor { store.load()?.items.count == 2 })
        player.clearQueue()
        #expect(await waitFor { store.load()?.items.isEmpty == true })
    }

    @Test func flushWritesImmediatelyAndCancelsThePendingSave() async {
        let (dir, store) = makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let player = Player()
        let saver = QueueAutosaver(output: LocalPlayerOutput(player: player), store: store, delay: .milliseconds(50))
        saver.start()
        player.enqueue(tracks(1))
        await Task.yield()
        saver.flush()
        #expect(store.load()?.items.count == 1)
        #expect(saver.saveCount == 1)
        try? await Task.sleep(for: .milliseconds(200))
        #expect(saver.saveCount == 1)
    }

    @Test func restoreDoesNotTriggerASave() async {
        let (dir, store) = makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let output = LocalPlayerOutput(player: Player())
        output.restore(QueueSnapshot(items: tracks(2).map { LocalQueueItem(track: $0, id: nil) }, currentIndex: 0, repeatMode: .off, isShuffled: false))
        let saver = QueueAutosaver(output: output, store: store, delay: .milliseconds(50))
        saver.start()
        try? await Task.sleep(for: .milliseconds(250))
        #expect(saver.saveCount == 0)
        #expect(!FileManager.default.fileExists(atPath: store.fileURL.path))
    }

    @Test func flushWithoutChangesLeavesTheFileAlone() throws {
        let (dir, store) = makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let newer = Data(#"{"version":2,"items":[],"repeat":"off","shuffle":false}"#.utf8)
        try newer.write(to: store.fileURL)
        #expect(store.load() == nil)
        let saver = QueueAutosaver(output: LocalPlayerOutput(player: Player()), store: store, delay: .milliseconds(50))
        saver.start()
        saver.flush()
        #expect(saver.saveCount == 0)
        #expect(try Data(contentsOf: store.fileURL) == newer)
    }

    @Test func saveNowWritesEvenWithoutChanges() {
        let (dir, store) = makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let output = LocalPlayerOutput(player: Player())
        let restored = tracks(2)
        output.restore(QueueSnapshot(items: restored.map { LocalQueueItem(track: $0, id: nil) }, currentIndex: 0, repeatMode: .off, isShuffled: false))
        let saver = QueueAutosaver(output: output, store: store, delay: .milliseconds(50))
        saver.start()
        saver.saveNow()
        #expect(FileManager.default.fileExists(atPath: store.fileURL.path))
        #expect(store.load()?.items.map(\.track.id) == restored.map(\.id))
        #expect(saver.saveCount == 1)
    }
}

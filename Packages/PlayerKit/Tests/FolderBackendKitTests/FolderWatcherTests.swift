import Foundation
import Testing
import os
@testable import FolderBackendKit

@MainActor
@Suite struct FolderWatcherTests {
    @Test func fsEventsReportAChangeInsideTheFolder() async throws {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let count = OSAllocatedUnfairLock(initialState: 0)
        let watcher = FSEventsFolderWatcher(url: dir, latency: 0.2) { count.withLock { $0 += 1 } }
        #expect(watcher.isRunning)

        // Events that land before the stream is live are lost, so keep writing (into a folder made after
        // the watcher started) until one is reported. The wait is bounded, not a fixed sleep.
        let nested = dir.appending(path: "Artist/Album")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        var written = 0
        let seen = await waitFor(timeout: 30) {
            written += 1
            try? Data("x".utf8).write(to: nested.appending(path: "file-\(written).txt"))
            return count.withLock { $0 } > 0
        }
        #expect(seen)

        watcher.stop()
        #expect(!watcher.isRunning)
        let after = count.withLock { $0 }
        try Data("y".utf8).write(to: nested.appending(path: "after-stop.txt"))
        try await Task.sleep(for: .seconds(1))  // the one fixed wait: proving that nothing arrives
        #expect(count.withLock { $0 } == after)
    }

    @Test func stopIsIdempotentAndSafeFromDeinit() {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        do {
            let watcher = FSEventsFolderWatcher(url: dir, latency: 0.2) {}
            watcher.stop()
            watcher.stop()
            #expect(!watcher.isRunning)
        }
        do {
            let watcher = FSEventsFolderWatcher(url: dir, latency: 0.2) {}
            #expect(watcher.isRunning)
        }  // deinit stops it
    }
}

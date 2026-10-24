import AudioCore
import Foundation
import MusicBackendKit
import Testing
@testable import LocalPlayback

/// Polls until `condition` holds (up to `timeout` seconds). No fixed sleeps in the happy path.
@MainActor
func waitFor(timeout: TimeInterval = 5, _ condition: () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return condition()
}

/// A track whose file cannot be opened, so the player never reaches the audio engine.
func unreadableItem(_ title: String, id: String?) -> LocalQueueItem {
    let url = URL(fileURLWithPath: "/nonexistent/\(UUID().uuidString).wav")
    return LocalQueueItem(
        track: Track(title: title, artist: "Artist", album: "Album", duration: 10, source: .file(url)),
        id: id.map { MediaID(.track, $0) })
}

@MainActor
struct LocalPlayerOutputTests {
    @Test func streamYieldsTheIdleSnapshotFirst() async throws {
        let output = LocalPlayerOutput(player: Player())
        var iterator = output.nowPlaying().makeAsyncIterator()
        let first = try #require(await iterator.next())
        #expect(first.state == .stopped)
        #expect(first.item == nil)
        #expect(first.output == OutputDevice.thisMacID)
    }

    @Test func replacePlaysTheStartIndexAndCarriesTheMediaID() async throws {
        let player = Player()
        let output = LocalPlayerOutput(player: player)
        let a = unreadableItem("A", id: "1"), b = unreadableItem("B", id: "2")
        var iterator = output.nowPlaying().makeAsyncIterator()
        _ = await iterator.next()
        output.play([a, b], mode: .replace(startIndex: 1))
        #expect(player.queue.currentIndex == 1)
        let snapshot = output.snapshot()
        #expect(snapshot.item == b.id)
        #expect(snapshot.title == "B")
        #expect(snapshot.state == .loading)
        #expect(await waitFor { player.errorMessage != nil })
        #expect(output.snapshot().state == .stopped)
    }

    @Test func appendOnlyStartsAnIdleEmptyPlayer() async throws {
        let player = Player()
        let output = LocalPlayerOutput(player: player)
        output.play([unreadableItem("A", id: "1")], mode: .append)
        #expect(player.queue.currentIndex == 0)
        #expect(await waitFor { player.errorMessage != nil })
        output.play([unreadableItem("B", id: "2")], mode: .append)
        #expect(player.queue.tracks.count == 2)
        #expect(player.queue.currentIndex == 0)
    }

    @Test func nextAppendsAndPutsTheNewEntriesAtTheFrontOfUpNext() async throws {
        let player = Player()
        let output = LocalPlayerOutput(player: player)
        let a = unreadableItem("A", id: "1"), b = unreadableItem("B", id: "2")
        let c = unreadableItem("C", id: "3"), d = unreadableItem("D", id: "4")
        output.play([a, b], mode: .replace())
        #expect(await waitFor { player.errorMessage != nil })
        // An unreadable A may skip on to B; whichever is current must stay current.
        let current = player.queue.currentIndex
        player.appendUpNext([b.track.id])
        output.play([c, d], mode: .next)
        #expect(player.queue.tracks.map(\.title) == ["A", "B", "C", "D"])
        #expect(player.queue.currentIndex == current)
        #expect(player.queue.upNext == [c.track.id, d.track.id, b.track.id])
        #expect(output.queueSnapshot().items[2].id == MediaID(.track, "3"))
    }

    @Test func nextOnAnIdlePlayerStartsTheFirstNewTrack() async throws {
        let player = Player()
        let output = LocalPlayerOutput(player: player)
        output.play([unreadableItem("C", id: "3"), unreadableItem("D", id: "4")], mode: .next)
        #expect(player.queue.currentIndex == 0)
        #expect(player.queue.tracks.map(\.title) == ["C", "D"])
        #expect(player.queue.upNext.isEmpty)
    }

    @Test func insertPutsItemsAtTheRowAndCarriesMediaIDs() async throws {
        let player = Player()
        let output = LocalPlayerOutput(player: player)
        let a = unreadableItem("A", id: "1"), b = unreadableItem("B", id: "2"), c = unreadableItem("C", id: "3")
        let x = unreadableItem("X", id: "8"), y = unreadableItem("Y", id: "9")
        output.play([a, b, c], mode: .replace(startIndex: 1))
        #expect(await waitFor { player.errorMessage != nil })
        // An unreadable B may skip on; whichever track is current must stay current.
        let current = try #require(player.queue.current?.id)
        output.play([x, y], mode: .insert(at: 1))
        #expect(player.queue.tracks.map(\.title) == ["A", "X", "Y", "B", "C"])
        #expect(player.queue.current?.id == current)
        let items = output.queueSnapshot().items
        #expect(items[1].id == MediaID(.track, "8"))
        #expect(items[2].id == MediaID(.track, "9"))
    }

    @Test func insertOnAnIdlePlayerStartsTheFirstInsertedTrack() async throws {
        let player = Player()
        let output = LocalPlayerOutput(player: player)
        output.play([unreadableItem("X", id: "8"), unreadableItem("Y", id: "9")], mode: .insert(at: 4))
        #expect(player.queue.tracks.map(\.title) == ["X", "Y"])
        #expect(player.queue.currentIndex == 0)
    }

    @Test func insertClampsAPastTheEndRowToAppend() async throws {
        let player = Player()
        let output = LocalPlayerOutput(player: player)
        output.play([unreadableItem("A", id: "1"), unreadableItem("B", id: "2")], mode: .replace())
        #expect(await waitFor { player.errorMessage != nil })
        output.play([unreadableItem("X", id: "8")], mode: .insert(at: 99))
        #expect(player.queue.tracks.map(\.title) == ["A", "B", "X"])
    }

    @Test func performRoutesVolumeAndStop() async throws {
        let player = Player()
        let output = LocalPlayerOutput(player: player)
        var iterator = output.nowPlaying().makeAsyncIterator()
        _ = await iterator.next()
        output.perform(.setVolume(0.25))
        #expect(player.volume == 0.25)
        let snapshot = try #require(await iterator.next())
        #expect(snapshot.volume == 0.25)
        output.perform(.stop)
        #expect(output.snapshot().state == .stopped)
        #expect(player.currentTime == 0)
    }

    @Test func performRoutesBalanceShuffleAndRepeat() {
        let player = Player()
        let output = LocalPlayerOutput(player: player)
        output.perform(.setBalance(-0.5))
        #expect(player.balance == -0.5)
        output.perform(.setShuffle(true))
        #expect(player.isShuffled)
        output.perform(.setShuffle(false))
        #expect(!player.isShuffled)
        output.perform(.setRepeat(true))
        #expect(player.repeatMode == .all)
        output.perform(.setRepeat(false))
        #expect(player.repeatMode == .off)
    }

    @Test func registryIgnoresTracksEnqueuedOutsideTheOutput() async throws {
        let player = Player()
        let output = LocalPlayerOutput(player: player)
        player.enqueue([unreadableItem("Local", id: nil).track])
        player.play()
        #expect(output.snapshot().item == nil)
        #expect(output.snapshot().title == "Local")
        #expect(await waitFor { player.errorMessage != nil })
    }

    @Test func cancellingTheSubscriptionRemovesTheObserver() async throws {
        let output = LocalPlayerOutput(player: Player())
        let stream = output.nowPlaying()
        let task = Task { @MainActor in
            for await _ in stream {}
        }
        #expect(output.subscriberCount == 1)
        task.cancel()
        #expect(await waitFor { output.subscriberCount == 0 })
    }


    @Test func eqPassesThroughToThePlayer() {
        let player = Player()
        let output = LocalPlayerOutput(player: player)
        output.eq[band: 3] = 6
        #expect(player.eq[band: 3] == 6)
        player.eq.preamp = -4
        #expect(output.eq.preamp == -4)
        output.eq = EQState(isEnabled: false)
        #expect(player.eq == EQState(isEnabled: false))
    }
}

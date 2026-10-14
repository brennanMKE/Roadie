import Foundation
import MusicBackendKit
import MusicBackendStub
import Testing

@MainActor
struct StubMusicBackendTests {
    @Test func gateSuspendsAndReleaseResumes() async {
        let backend = StubMusicBackend()
        await backend.gate(.connect)
        let task = Task { try await backend.connect() }
        #expect(await waitFor { await backend.suspendedCount == 1 })
        #expect(!(await backend.isConnected))
        await backend.release(.connect)
        _ = try? await task.value
        #expect(await backend.isConnected)
        #expect(await backend.suspendedCount == 0)
    }

    @Test func gatedCallCancelsCleanly() async {
        let backend = StubMusicBackend()
        await backend.gate(.artists)
        let task = Task { try await backend.artists(page: .first) }
        #expect(await waitFor { await backend.suspendedCount == 1 })
        task.cancel()
        #expect(await waitFor { await backend.cancelledCount == 1 })
        #expect(await backend.suspendedCount == 0)
        let result = await task.result
        if case .failure(let error) = result {
            #expect(error is CancellationError)
        } else {
            Issue.record("expected a cancellation")
        }
    }

    @Test func errorsAreStickyUntilCleared() async throws {
        let backend = StubMusicBackend()
        await backend.setError(.unreachable("down"), for: .artists)
        for _ in 0..<2 {
            await #expect(throws: MusicBackendError.unreachable("down")) {
                _ = try await backend.artists(page: .first)
            }
        }
        await backend.setError(nil, for: .artists)
        let page = try await backend.artists(page: .first)
        #expect(page.items.count == 25)
    }

    @Test func pagingMatchesPageMake() async throws {
        let backend = StubMusicBackend()
        let page = try await backend.artists(page: PageRequest(offset: 20, limit: 10))
        #expect(page.items.count == 5)
        #expect(page.nextOffset == nil)
        #expect(page.total == 25)
        let quiet = StubMusicBackend(reportsTotals: false)
        let noTotal = try await quiet.artists(page: PageRequest(offset: 0, limit: 10))
        #expect(noTotal.total == nil)
        #expect(noTotal.nextOffset == 10)
    }
}

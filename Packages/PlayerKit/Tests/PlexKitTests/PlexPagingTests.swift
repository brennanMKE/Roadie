import Foundation
import Testing
import PlexKit

struct PlexPagingTests {
    @Test func nextPageArithmetic() {
        let first = PlexPage(items: [1, 2, 3], offset: 0, size: 3, totalSize: 7)
        #expect(first.next == PlexPageRequest(start: 3, size: 3))
        let last = PlexPage(items: [7], offset: 6, size: 1, totalSize: 7)
        #expect(last.next == nil)
        let empty = PlexPage<Int>(items: [], offset: 0, size: 0, totalSize: 0)
        #expect(!empty.hasMore)
    }

    @Test func clientIdentifierIsStableAcrossCalls() throws {
        let suite = "PlexKitTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let first = PlexClientIdentifier.stored(in: defaults)
        let second = PlexClientIdentifier.stored(in: defaults)
        #expect(first == second)
        #expect(UUID(uuidString: first) != nil)
    }
}

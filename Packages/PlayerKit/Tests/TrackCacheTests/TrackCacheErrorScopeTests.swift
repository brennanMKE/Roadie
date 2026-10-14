import AudioCore
import Foundation
import PlexKit
import Testing

@testable import TrackCache

@Suite struct TrackCacheErrorScopeTests {
    @Test func trackCacheErrorsClassifyBySource() {
        let wholeSource: [TrackCacheError] = [
            .noServer, .serverMismatch, .io("full"),
            .download(.transport(.cannotConnectToHost)), .download(.unauthorized),
        ]
        for error in wholeSource { #expect(error.affectsWholeSource, "\(error)") }
        let perTrack: [TrackCacheError] = [
            .notPlexTrack, .sizeMismatch(expected: 1, actual: 0),
            .download(.notFound), .download(.httpStatus(500)),
        ]
        for error in perTrack { #expect(!error.affectsWholeSource, "\(error)") }
    }
}

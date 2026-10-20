import AudioCore
import Testing
@testable import LocalPlayback

@MainActor
@Suite struct LocalPlaybackStackTests {
    @Test func standardBuildsOneStoppedPlayerBehindTheOutput() {
        let stack = LocalPlaybackStack.standard()
        #expect(stack.output.player === stack.player)
        #expect(stack.player.state == .stopped)
        #expect(stack.player.queue.tracks.isEmpty)
        #expect(stack.output.snapshot().state == .stopped)
        #expect(stack.output.subscriberCount == 0)
    }
}

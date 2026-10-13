import Testing
@testable import AudioCore

@MainActor
@Suite struct PlayerTests {
    @Test func volumeIsClamped() {
        let p = Player()
        p.volume = 1.5
        #expect(p.volume == 1)
        p.volume = -0.5
        #expect(p.volume == 0)
        p.volume = 0.4
        #expect(p.volume == 0.4)
    }

    @Test func balanceIsClamped() {
        let p = Player()
        p.balance = 2
        #expect(p.balance == 1)
        p.balance = -2
        #expect(p.balance == -1)
        p.balance = 0.3
        #expect(p.balance == 0.3)
    }

    @Test func repeatedAssignmentDoesNotCrash() {
        let p = Player()
        for i in 0..<1000 {
            p.volume = Float(i % 7) / 3 - 0.5
            p.balance = Float(i % 5) - 2
        }
        #expect((0...1).contains(p.volume))
        #expect((-1...1).contains(p.balance))
    }

    @Test func graphCreatedLaterReceivesClampedValues() {
        let p = Player()
        p.volume = 1.5
        p.balance = -3
        let graph = p.ensureGraph()
        #expect(graph.engine.mainMixerNode.outputVolume == 1)
        #expect(graph.playerNode.pan == -1)
    }

    @Test func existingGraphReceivesClampedValues() {
        let p = Player()
        let graph = p.ensureGraph()
        p.volume = 0.4
        p.balance = 0.3
        #expect(graph.engine.mainMixerNode.outputVolume == 0.4)
        #expect(graph.playerNode.pan == 0.3)
        p.volume = -0.5
        p.balance = 2
        #expect(graph.engine.mainMixerNode.outputVolume == 0)
        #expect(graph.playerNode.pan == 1)
    }
}

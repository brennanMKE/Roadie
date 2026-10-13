import Testing
@testable import AudioCore

@MainActor
@Suite struct AudioGraphTests {
    @Test func initialVolumeAndBalanceReachTheNodes() {
        let graph = AudioGraph(volume: 0.25, balance: -1)
        #expect(graph.engine.mainMixerNode.outputVolume == 0.25)
        #expect(graph.playerNode.pan == -1)
    }

    @Test func initialValuesAreClamped() {
        let graph = AudioGraph(volume: 2, balance: -3)
        #expect(graph.engine.mainMixerNode.outputVolume == 1)
        #expect(graph.playerNode.pan == -1)
    }
}

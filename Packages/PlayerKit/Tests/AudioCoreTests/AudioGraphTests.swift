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

    @Test func graphStillConstructsHeadless() {
        let provider = ManualOutputDeviceProvider()
        let graph = AudioGraph(volume: 1, balance: 0, outputDevices: provider)
        #expect(graph.outputDevice == nil)
        #expect(provider.binds.isEmpty)
        #expect(graph.engine.isRunning == false)
    }
}

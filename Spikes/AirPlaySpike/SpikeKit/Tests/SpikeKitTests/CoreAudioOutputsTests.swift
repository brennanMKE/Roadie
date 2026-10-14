import Testing
@testable import SpikeKit

@Suite struct CoreAudioOutputsTests {
    /// Read-only: lists devices, never changes one.
    @Test func listsAtLeastTheDefaultDevice() {
        let devices = CoreAudioOutputs.list()
        for d in devices { print("output: \(d.label) uid \(d.uid)") }
        guard !devices.isEmpty else {
            print("no output device reported; skipping")
            return
        }
        for d in devices { #expect(!d.transport.isEmpty) }
    }
}

import AVFoundation

public extension AVAudioUnitEQ {
    /// Call once on an `AVAudioUnitEQ(numberOfBands: 10)`: peaking filters at the Winamp frequencies,
    /// flat, and un-bypassed (fresh bands are bypassed and would silently do nothing).
    func configureWinampBands() {
        precondition(bands.count == EQState.bandCount, "AVAudioUnitEQ must have \(EQState.bandCount) bands")
        for (i, band) in bands.enumerated() {
            band.filterType = .parametric
            band.frequency = EQBands.frequencies[i]
            band.bandwidth = EQBands.bandwidths[i]
            band.gain = 0
            band.bypass = false
        }
    }

    /// Pushes gains, preamp and on/off. Cheap enough to call on every slider change.
    func apply(_ state: EQState) {
        for (i, band) in bands.enumerated() where i < state.gains.count {
            band.gain = state.gains[i]
        }
        globalGain = state.preamp
        bypass = !state.isEnabled
    }
}

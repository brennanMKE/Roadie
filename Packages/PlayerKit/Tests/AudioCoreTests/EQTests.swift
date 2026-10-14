import AVFoundation
import Foundation
import Testing
@testable import AudioCore

@Suite struct EQTests {
    static var rock: EQPreset { EQPreset.builtIn.first { $0.name == "Rock" }! }

    @Test func gainsAndPreampClampToWinampRange() {
        var s = EQState()
        s.preamp = 20
        #expect(s.preamp == 12)
        s.gains[0] = -30
        #expect(s.gains[0] == -12)
        s.gains = [1, 2, 3]
        #expect(s.gains == [1, 2, 3, 0, 0, 0, 0, 0, 0, 0])
        s.gains = Array(repeating: 5, count: 12)
        #expect(s.gains.count == 10)
        s[band: 4] = 99
        #expect(s[band: 4] == 12)
        #expect(EQState(preamp: -50, gains: [40]).preamp == -12)
        #expect(EQState(gains: [40]).gains[0] == 12)
    }

    @Test func winampValueMapping() {
        #expect(EQPreset.decibels(fromWinampValue: 1) == -12)
        #expect(EQPreset.decibels(fromWinampValue: 33) == 0)
        #expect(EQPreset.decibels(fromWinampValue: 64) == 12)
        #expect(abs(EQPreset.decibels(fromWinampValue: 17) - -6.0) < 0.05)
        let all = (1...64).map(EQPreset.decibels(fromWinampValue:))
        for i in 1..<all.count { #expect(all[i] > all[i - 1]) }
    }

    @Test func builtInPresets() throws {
        let presets = EQPreset.builtIn
        #expect(presets.count == 18)
        #expect(Set(presets.map(\.name)).count == 18)
        #expect(presets[0].name == "Flat")
        #expect(presets[0].preamp == 0)
        #expect(presets[0].gains == Array(repeating: 0, count: 10))
        for p in presets {
            #expect(p.gains.count == 10)
            #expect(p.gains.allSatisfy { EQState.gainRange.contains($0) })
        }
        #expect(abs(Self.rock.gains[3] - -5.25) < 0.06)
    }

    @Test func applyingPresetKeepsEnabledFlag() {
        let s = EQState(isEnabled: false).applying(Self.rock)
        #expect(s.gains == Self.rock.gains)
        #expect(s.preamp == Self.rock.preamp)
        #expect(s.isEnabled == false)
    }

    @Test func applyConfiguresAVAudioUnitEQ() {
        let unit = AVAudioUnitEQ(numberOfBands: 10)
        unit.configureWinampBands()
        unit.apply(EQState(isEnabled: false, preamp: 3, gains: Self.rock.gains))
        for (i, band) in unit.bands.enumerated() {
            #expect(band.filterType == .parametric)
            #expect(band.frequency == EQBands.frequencies[i])
            #expect(abs(band.bandwidth - EQBands.bandwidths[i]) < 0.001)
            #expect(abs(band.gain - Self.rock.gains[i]) < 0.001)
            #expect(band.bypass == false)
        }
        #expect(unit.globalGain == 3)
        #expect(unit.bypass == true)
        unit.apply(.flat)
        #expect(unit.bypass == false)
        #expect(unit.globalGain == 0)
    }

    @Test func codableRoundTrip() throws {
        let state = EQState(isEnabled: false, preamp: -2.5, gains: [1, -2, 3, -4, 5, -6, 7, -8, 9, -10])
        let decoded = try JSONDecoder().decode(EQState.self, from: JSONEncoder().encode(state))
        #expect(decoded == state)
        let stale = try JSONDecoder().decode(EQState.self, from: Data(#"{"isEnabled":true,"preamp":40,"gains":[1,2,3]}"#.utf8))
        #expect(stale.preamp == 12)
        #expect(stale.gains == [1, 2, 3, 0, 0, 0, 0, 0, 0, 0])
        #expect(try JSONDecoder().decode(EQState.self, from: Data("{}".utf8)) == .flat)
    }
}

@MainActor
@Suite struct PlayerEQTests {
    @Test func eqIsStoredAndReachesTheGraph() {
        let player = Player()
        #expect(player.eq == .flat)
        player.eq.preamp = 50
        #expect(player.eq.preamp == 12)
        player.eq[band: 2] = 4
        var state = player.eq
        state.isEnabled = false
        player.eq = state
        #expect(player.eq[band: 2] == 4)
        // Graph created after the fact picks up the current state.
        let graph = player.ensureGraph()
        #expect(graph.eq.bypass == true)
        #expect(graph.eq.globalGain == 12)
        #expect(graph.eq.bands[2].gain == 4)
        // And later changes are pushed to the existing graph.
        player.eq = .flat
        #expect(graph.eq.bypass == false)
        #expect(graph.eq.bands[2].gain == 0)
    }
}

/// Renders a generated 1 kHz sine through a real `Player` in offline manual-rendering mode.
@MainActor
@Suite struct EQRenderTests {
    func renderedRMS(eq: EQState, hz: Double) async throws -> Float {
        let dir = FileManager.default.temporaryDirectory.appending(path: "eq-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appending(path: "sine.wav")
        let rate = GaplessRenderTests.rate
        let frames = 44100
        let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2)!
        var file: AVAudioFile? = try AVAudioFile(forWriting: url, settings: format.settings)
        let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))!
        buf.frameLength = AVAudioFrameCount(frames)
        for ch in 0..<2 {
            for i in 0..<frames { buf.floatChannelData![ch][i] = Float(0.1 * sin(2 * .pi * hz * Double(i) / rate)) }
        }
        try file?.write(from: buf)
        file = nil  // close so the header is finalized before reading

        let player = Player()
        player.eq = eq
        player.enqueue([try Track.file(at: url)])
        let engine = player.ensureGraph().engine
        try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 512)
        player.play()
        for _ in 0..<500 where player.state != .playing { try await Task.sleep(for: .milliseconds(10)) }
        #expect(player.state == .playing)

        let out = AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat, frameCapacity: 512)!
        var sum: Double = 0
        var count = 0
        for block in 0..<70 {
            _ = try engine.renderOffline(512, to: out)
            // The node reads its schedule on another thread; give it time, then skip filter settling.
            try await Task.sleep(for: .milliseconds(2))
            if block < 20 { continue }
            let data = out.floatChannelData![0]
            for i in 0..<Int(out.frameLength) { sum += Double(data[i] * data[i]); count += 1 }
        }
        player.stop()
        return Float((sum / Double(count)).squareRoot())
    }

    @Test func bandBoostAndCutChangeRenderedLevel() async throws {
        let flat = try await renderedRMS(eq: .flat, hz: 1000)
        #expect(flat > 0.05)  // 0.1 amplitude sine: RMS ~0.0707
        var boost = EQState.flat
        boost[band: 4] = 12  // 1 kHz
        var cut = EQState.flat
        cut[band: 4] = -12
        var off = boost
        off.isEnabled = false
        var otherBand = EQState.flat
        otherBand[band: 0] = 12  // 60 Hz boost should not touch a 1 kHz tone
        let boosted = try await renderedRMS(eq: boost, hz: 1000)
        let cutRMS = try await renderedRMS(eq: cut, hz: 1000)
        let disabled = try await renderedRMS(eq: off, hz: 1000)
        let elsewhere = try await renderedRMS(eq: otherBand, hz: 1000)
        #expect(boosted / flat > 3.0)   // +12 dB is ~3.98x
        #expect(cutRMS / flat < 0.35)   // -12 dB is ~0.25x
        #expect(abs(disabled / flat - 1) < 0.05)
        #expect(abs(elsewhere / flat - 1) < 0.15)
    }

    @Test func winampValueRoundTripsAllSixtyFourValues() {
        for v in 1...64 {
            #expect(EQPreset.winampValue(fromDecibels: EQPreset.decibels(fromWinampValue: v)) == v)
        }
        #expect(EQPreset.winampValue(fromDecibels: 12) == 64)
        #expect(EQPreset.winampValue(fromDecibels: -12) == 1)
        #expect(EQPreset.winampValue(fromDecibels: 0) == 33)
        #expect(EQPreset.winampValue(fromDecibels: 40) == 64)
        #expect(EQPreset.winampValue(fromDecibels: -40) == 1)
    }
}

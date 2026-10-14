import Foundation
import Testing
@testable import AudioCore

enum Tone {
    static func sine(_ hz: Double, rate: Double = 48_000, count: Int = 1024, amplitude: Float = 1) -> [Float] {
        (0..<count).map { amplitude * Float(sin(2 * .pi * hz * Double($0) / rate)) }
    }
}

@Suite struct SpectrumColumnMapTests {
    @Test func rangesAreWellFormed() {
        let map = SpectrumColumnMap(fftSize: 1024, sampleRate: 48_000)
        #expect(map.ranges.count == 75)
        #expect(map.ranges.allSatisfy { !$0.isEmpty })
        #expect(map.ranges[0].lowerBound >= 1)
        #expect(map.ranges.last!.upperBound <= 512)
        for i in 1..<75 { #expect(map.ranges[i].lowerBound >= map.ranges[i - 1].lowerBound) }
    }

    @Test func binLookupAndSampleRate() {
        let a = SpectrumColumnMap(fftSize: 1024, sampleRate: 48_000)
        let b = SpectrumColumnMap(fftSize: 1024, sampleRate: 44_100)
        #expect(a.bin(forFrequency: 1500) == 32)
        #expect(a.ranges != b.ranges)
    }
}

@Suite struct SpectrumAnalyzerTests {
    func peak(_ hz: Double, amplitude: Float = 1, analyzer: SpectrumAnalyzer) -> (column: Int, value: Float) {
        let frame = analyzer.analyze(Tone.sine(hz, count: analyzer.fftSize, amplitude: amplitude))
        let value = frame.spectrum.max()!
        return (frame.spectrum.firstIndex(of: value)!, value)
    }

    @Test func sineLandsInRightColumn() {
        let analyzer = SpectrumAnalyzer(sampleRate: 48_000)
        let p = peak(1500, analyzer: analyzer)
        #expect(analyzer.columnMap.ranges[p.column].contains(32))
        #expect(analyzer.columnMap.frequencyRange(ofColumn: p.column).contains(1500))
    }

    @Test func peaksIncreaseWithFrequency() {
        let analyzer = SpectrumAnalyzer(sampleRate: 48_000)
        let low = peak(93.75, analyzer: analyzer).column
        let mid = peak(1500, analyzer: analyzer).column
        let high = peak(12_000, analyzer: analyzer).column
        #expect(low < mid && mid < high)
        #expect((25...55).contains(mid))
    }

    @Test func levelsAreCalibrated() {
        let analyzer = SpectrumAnalyzer(sampleRate: 48_000)
        #expect(peak(1500, analyzer: analyzer).value >= 0.9)
        let quiet = peak(1500, amplitude: 0.1, analyzer: analyzer).value
        #expect(abs(quiet - 0.667) <= 0.03)
    }

    @Test func silenceIsFloor() {
        let analyzer = SpectrumAnalyzer(sampleRate: 48_000)
        let frame = analyzer.analyze([Float](repeating: 0, count: 1024))
        #expect(frame.spectrum.allSatisfy { $0 == 0 })
        #expect(frame.scope.allSatisfy { $0 == 0 })
    }

    @Test func scopeFollowsInput() {
        let analyzer = SpectrumAnalyzer(sampleRate: 48_000)
        let sine = analyzer.analyze(Tone.sine(1500, amplitude: 0.8))
        #expect(sine.scope.count == 76)
        #expect(sine.scope.allSatisfy { (-1...1).contains($0) })
        #expect(abs(sine.scope.max()! - 0.8) < 0.1)
        let dc = analyzer.analyze([Float](repeating: 0.5, count: 1024))
        #expect(dc.scope.allSatisfy { $0 == 0.5 })
    }

    @Test(arguments: [1024, 2048]) func shape(fftSize: Int) {
        let analyzer = SpectrumAnalyzer(fftSize: fftSize, sampleRate: 48_000)
        let frame = analyzer.analyze(Tone.sine(1500, count: fftSize))
        #expect(frame.spectrum.count == 75)
        #expect(frame.scope.count == 76)
    }
}

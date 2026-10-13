import Accelerate
import Foundation

/// vDSP FFT -> log-spaced columns in dB, plus a downsampled oscilloscope trace.
/// All scratch is allocated in `init`; `analyze(_:spectrum:scope:)` does not allocate.
/// Not thread-safe: one owner.
public final class SpectrumAnalyzer {
    public let fftSize: Int
    public let columnCount: Int
    public let scopeLength: Int
    public let scopeStride: Int
    public let floorDB: Float
    public let columnMap: SpectrumColumnMap

    private let log2n: vDSP_Length
    private let setup: FFTSetup
    private let window: UnsafeMutablePointer<Float>
    private let windowed: UnsafeMutablePointer<Float>
    private let realp: UnsafeMutablePointer<Float>
    private let imagp: UnsafeMutablePointer<Float>
    private let power: UnsafeMutablePointer<Float>
    /// Full-scale sine under a Hann window: |zrip output| = N/2, so power reference = (N/2)^2.
    private let referencePower: Float

    public init(fftSize: Int = 1024, sampleRate: Double, columnCount: Int = 75,
                scopeLength: Int = 76, scopeStride: Int = 8, floorDB: Float = -60) {
        precondition(fftSize >= 64 && fftSize & (fftSize - 1) == 0, "fftSize must be a power of two")
        self.fftSize = fftSize
        self.columnCount = columnCount
        self.scopeLength = scopeLength
        self.scopeStride = scopeStride
        self.floorDB = floorDB
        columnMap = SpectrumColumnMap(fftSize: fftSize, sampleRate: sampleRate, columnCount: columnCount)
        log2n = vDSP_Length(fftSize.trailingZeroBitCount)
        setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))!
        let half = fftSize / 2
        window = .allocate(capacity: fftSize)
        windowed = .allocate(capacity: fftSize)
        realp = .allocate(capacity: half)
        imagp = .allocate(capacity: half)
        power = .allocate(capacity: half)
        vDSP_hann_window(window, vDSP_Length(fftSize), Int32(vDSP_HANN_DENORM))
        referencePower = Float(half) * Float(half)
    }

    deinit {
        vDSP_destroy_fftsetup(setup)
        window.deallocate(); windowed.deallocate()
        realp.deallocate(); imagp.deallocate(); power.deallocate()
    }

    /// `samples.count == fftSize`; `spectrum.count >= columnCount`; `scope.count >= scopeLength`.
    public func analyze(_ samples: UnsafeBufferPointer<Float>,
                        spectrum: UnsafeMutableBufferPointer<Float>,
                        scope: UnsafeMutableBufferPointer<Float>) {
        precondition(samples.count == fftSize && spectrum.count >= columnCount && scope.count >= scopeLength)
        let n = vDSP_Length(fftSize)
        let half = fftSize / 2
        vDSP_vmul(samples.baseAddress!, 1, window, 1, windowed, 1, n)
        var split = DSPSplitComplex(realp: realp, imagp: imagp)
        windowed.withMemoryRebound(to: DSPComplex.self, capacity: half) {
            vDSP_ctoz($0, 2, &split, 1, vDSP_Length(half))
        }
        vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
        imagp[0] = 0 // packed Nyquist term; bin 0 is not displayed
        vDSP_zvmags(&split, 1, power, 1, vDSP_Length(half))

        for c in 0..<columnCount {
            let r = columnMap.ranges[c]
            var sum: Float = 0
            vDSP_sve(power + r.lowerBound, 1, &sum, vDSP_Length(r.count))
            let db = 10 * log10f(sum / referencePower + 1e-12)
            spectrum[c] = min(max((db - floorDB) / -floorDB, 0), 1)
        }

        let base = fftSize - scopeLength * scopeStride
        for i in 0..<scopeLength {
            scope[i] = min(max(samples[base + i * scopeStride], -1), 1)
        }
    }

    /// Convenience for tests (allocates).
    public func analyze(_ samples: [Float]) -> VisFrame {
        var spectrum = [Float](repeating: 0, count: columnCount)
        var scope = [Float](repeating: 0, count: scopeLength)
        samples.withUnsafeBufferPointer { s in
            spectrum.withUnsafeMutableBufferPointer { sp in
                scope.withUnsafeMutableBufferPointer { sc in analyze(s, spectrum: sp, scope: sc) }
            }
        }
        return VisFrame(spectrum: spectrum, scope: scope, sampleCount: 0)
    }
}

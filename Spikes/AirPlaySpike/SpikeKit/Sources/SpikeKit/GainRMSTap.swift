@preconcurrency import AVFoundation
import Accelerate
import CoreMedia
import MediaToolbox
import os

/// State shared between the audio thread (tap callbacks) and the main thread.
public final class GainRMSTap: @unchecked Sendable {
    public struct Snapshot: Sendable {
        public var gain: Float = 1
        public var rms: Float = 0
        public var lastProcessedEnd: TimeInterval = 0
        public var lastHostTime: UInt64 = 0
        public var processCalls: Int = 0
        public var format: String = "not prepared"
    }

    private let state = OSAllocatedUnfairLock(initialState: Snapshot())
    private let log: SpikeLog
    private let isFloat = OSAllocatedUnfairLock(initialState: true)

    public init(log: SpikeLog) { self.log = log }

    public var snapshot: Snapshot { state.withLock { $0 } }

    public func setGain(_ gain: Float) {
        state.withLock { $0.gain = max(0, min(1, gain)) }
    }

    fileprivate func prepared(_ asbd: AudioStreamBasicDescription, maxFrames: Int) {
        let float = asbd.mFormatFlags & kAudioFormatFlagIsFloat != 0 && asbd.mBitsPerChannel == 32
        isFloat.withLock { $0 = float }
        let text = "rate \(asbd.mSampleRate) ch \(asbd.mChannelsPerFrame) bits \(asbd.mBitsPerChannel) flags \(asbd.mFormatFlags) maxFrames \(maxFrames)"
        state.withLock { $0.format = text }
        log.log("A+tap", "tap prepare: \(text)")
    }

    fileprivate func unprepared() { log.log("A+tap", "tap unprepare") }

    fileprivate func processed(_ list: UnsafeMutablePointer<AudioBufferList>, end: TimeInterval) {
        let gain = state.withLock { $0.gain }
        let float = isFloat.withLock { $0 }
        var sumSquares: Float = 0
        var samples = 0
        if float {
            for buffer in UnsafeMutableAudioBufferListPointer(list) {
                guard let data = buffer.mData?.assumingMemoryBound(to: Float.self) else { continue }
                let n = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size
                guard n > 0 else { continue }
                var g = gain
                vDSP_vsmul(data, 1, &g, data, 1, vDSP_Length(n))
                var rms: Float = 0
                vDSP_rmsqv(data, 1, &rms, vDSP_Length(n))
                sumSquares += rms * rms * Float(n)
                samples += n
            }
        }
        let rms = samples > 0 ? (sumSquares / Float(samples)).squareRoot() : 0
        let host = mach_absolute_time()
        state.withLock {
            $0.rms = rms
            $0.lastProcessedEnd = end
            $0.lastHostTime = host
            $0.processCalls += 1
        }
    }

    /// Builds an MTAudioProcessingTap that retains `self` until the tap is finalized.
    public func makeTap() -> MTAudioProcessingTap? {
        var callbacks = MTAudioProcessingTapCallbacks(
            version: kMTAudioProcessingTapCallbacksVersion_0,
            clientInfo: Unmanaged.passRetained(self).toOpaque(),
            init: { _, clientInfo, storageOut in storageOut.pointee = clientInfo },
            finalize: { tap in
                Unmanaged<GainRMSTap>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).release()
            },
            prepare: { tap, maxFrames, asbd in
                Unmanaged<GainRMSTap>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).takeUnretainedValue()
                    .prepared(asbd.pointee, maxFrames: maxFrames)
            },
            unprepare: { tap in
                Unmanaged<GainRMSTap>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).takeUnretainedValue().unprepared()
            },
            process: { tap, frames, _, bufferList, framesOut, flagsOut in
                var range = CMTimeRange()
                let status = MTAudioProcessingTapGetSourceAudio(tap, frames, bufferList, flagsOut, &range, framesOut)
                guard status == noErr else { return }
                let end = CMTimeAdd(range.start, range.duration).seconds
                Unmanaged<GainRMSTap>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).takeUnretainedValue()
                    .processed(bufferList, end: end)
            })
        var tap: MTAudioProcessingTap?
        let status = MTAudioProcessingTapCreate(kCFAllocatorDefault, &callbacks, kMTAudioProcessingTapCreationFlag_PreEffects, &tap)
        if status != noErr {
            // The retain taken for clientInfo is only balanced by finalize, which never runs on failure.
            Unmanaged.passUnretained(self).release()
            return nil
        }
        return tap
    }
}

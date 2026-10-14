import AVFoundation
import CoreMedia
import Testing
@testable import SpikeKit

@Suite struct SampleBufferPackagerTests {
    @Test func packagesInterleavedFloat32() throws {
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 2, interleaved: true)!
        let frames: AVAudioFrameCount = 4800
        let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        pcm.frameLength = frames
        let samples = pcm.audioBufferList.pointee.mBuffers.mData!.assumingMemoryBound(to: Float.self)
        for i in 0..<Int(frames) {
            samples[2 * i] = Float(i) / Float(frames)
            samples[2 * i + 1] = -Float(i) / Float(frames)
        }
        let pts = CMTime(value: 96_000, timescale: 48_000)
        let sample = try SampleBufferPackager.make(from: pcm, presentationTime: pts)

        #expect(CMSampleBufferGetNumSamples(sample) == 4800)
        #expect(CMTimeCompare(CMSampleBufferGetPresentationTimeStamp(sample), pts) == 0)
        #expect(abs(CMSampleBufferGetDuration(sample).seconds - 0.1) < 1e-6)
        let desc = try #require(CMSampleBufferGetFormatDescription(sample))
        let asbd = try #require(CMAudioFormatDescriptionGetStreamBasicDescription(desc)).pointee
        #expect(asbd.mSampleRate == 48_000)
        #expect(asbd.mChannelsPerFrame == 2)
        #expect(asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved == 0)
        #expect(asbd.mFormatFlags & kAudioFormatFlagIsFloat != 0)

        // Overwrite the source after packaging: the sample buffer must hold its own copy.
        let block = try #require(CMSampleBufferGetDataBuffer(sample))
        samples[0] = 99
        var out = [Float](repeating: 0, count: 2 * Int(frames))
        let status = CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: out.count * MemoryLayout<Float>.size, destination: &out)
        #expect(status == noErr)
        #expect(out[0] == 0)
        #expect(out[1] == 0)
        #expect(out[2 * 4799] == Float(4799) / Float(frames))
        #expect(out[2 * 4799 + 1] == -Float(4799) / Float(frames))
    }

    @Test func consecutiveBuffersAreContiguous() throws {
        let one = try writeRampFile(seconds: 0.5, rate: 44_100)
        let two = try writeRampFile(seconds: 0.5, rate: 48_000)
        let source = try PCMSource(urls: [one, two])
        var buffers: [CMSampleBuffer] = []
        while let b = source.next() { buffers.append(b) }
        // AVAudioFile may return fewer frames than asked, so a file can come back as several buffers.
        #expect(buffers.count >= 2)
        for (earlier, later) in zip(buffers, buffers.dropFirst()) {
            let end = CMTimeAdd(CMSampleBufferGetPresentationTimeStamp(earlier), CMSampleBufferGetDuration(earlier))
            #expect(CMTimeCompare(CMSampleBufferGetPresentationTimeStamp(later), end) == 0)
        }
        #expect(CMTimeCompare(CMSampleBufferGetPresentationTimeStamp(buffers[0]), .zero) == 0)
        func rate(_ b: CMSampleBuffer) -> Double {
            CMAudioFormatDescriptionGetStreamBasicDescription(CMSampleBufferGetFormatDescription(b)!)!.pointee.mSampleRate
        }
        let firstOf48k = try #require(buffers.first { rate($0) == 48_000 })
        // The second file starts exactly where the first one (22 050 frames at 44.1 kHz) ends.
        #expect(CMTimeCompare(CMSampleBufferGetPresentationTimeStamp(firstOf48k), CMTime(value: 22_050, timescale: 44_100)) == 0)
        #expect(abs(source.lastEnqueuedEnd - 1.0) < 1e-4)
    }

    @Test func longFileSplitsIntoChunksWithMonotonicTimeline() throws {
        let url = try writeRampFile(seconds: 4, rate: 48_000)
        let source = try PCMSource(urls: [url])
        var last = CMTime.negativeInfinity
        var count = 0
        while let b = source.next() {
            let pts = CMSampleBufferGetPresentationTimeStamp(b)
            #expect(CMTimeCompare(pts, last) > 0)
            last = pts
            count += 1
        }
        #expect(count >= 3)
    }
}

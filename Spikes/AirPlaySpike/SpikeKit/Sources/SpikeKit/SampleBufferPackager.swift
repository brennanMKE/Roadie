import AVFoundation
import CoreMedia

public enum SampleBufferPackagerError: Error, Equatable {
    case notInterleavedFloat32
    case coreMedia(String, Int32)
}

/// Pure: interleaved Float32 PCM plus a presentation time into a ready CMSampleBuffer. The bytes are copied, so
/// the result does not point into the PCM buffer.
public enum SampleBufferPackager {
    public static func make(from buffer: AVAudioPCMBuffer, presentationTime: CMTime) throws -> CMSampleBuffer {
        let format = buffer.format
        guard format.commonFormat == .pcmFormatFloat32, format.isInterleaved else {
            throw SampleBufferPackagerError.notInterleavedFloat32
        }
        var asbd = format.streamDescription.pointee
        var formatDescription: CMAudioFormatDescription?
        var status = CMAudioFormatDescriptionCreate(
            allocator: kCFAllocatorDefault, asbd: &asbd, layoutSize: 0, layout: nil,
            magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &formatDescription)
        guard status == noErr, let formatDescription else { throw SampleBufferPackagerError.coreMedia("CMAudioFormatDescriptionCreate", status) }

        let frames = Int(buffer.frameLength)
        let byteCount = frames * Int(asbd.mBytesPerFrame)
        guard let src = buffer.audioBufferList.pointee.mBuffers.mData, byteCount > 0 else {
            throw SampleBufferPackagerError.coreMedia("empty buffer", -1)
        }
        var block: CMBlockBuffer?
        status = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: byteCount,
            blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0,
            dataLength: byteCount, flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &block)
        guard status == noErr, let block else { throw SampleBufferPackagerError.coreMedia("CMBlockBufferCreateWithMemoryBlock", status) }
        status = CMBlockBufferReplaceDataBytes(with: src, blockBuffer: block, offsetIntoDestination: 0, dataLength: byteCount)
        guard status == noErr else { throw SampleBufferPackagerError.coreMedia("CMBlockBufferReplaceDataBytes", status) }

        var sample: CMSampleBuffer?
        status = CMAudioSampleBufferCreateReadyWithPacketDescriptions(
            allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: formatDescription,
            sampleCount: frames, presentationTimeStamp: presentationTime, packetDescriptions: nil,
            sampleBufferOut: &sample)
        guard status == noErr, let sample else { throw SampleBufferPackagerError.coreMedia("CMAudioSampleBufferCreateReadyWithPacketDescriptions", status) }
        return sample
    }
}

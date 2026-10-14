import AVFoundation
import CoreMedia
import Foundation

/// Decodes a list of audio files into 1.5 s interleaved Float32 CMSampleBuffers on one continuous timeline.
/// Owned by the feed queue; a lock makes the few shared reads (lead measurement) safe from the main thread.
public final class PCMSource: @unchecked Sendable {
    public static let chunkSeconds = 1.5

    struct Entry {
        let url: URL
        let sampleRate: Double
        let frames: AVAudioFramePosition
        let start: CMTime        // where this file begins on the shared timeline
        var duration: CMTime { CMTime(value: frames, timescale: CMTimeScale(sampleRate)) }
    }

    private let lock = NSLock()
    private var entries: [Entry] = []
    private var index = 0
    private var file: AVAudioFile?
    private var enqueuedEnd = CMTime.zero
    public let totalDuration: TimeInterval

    public init(urls: [URL]) throws {
        var offset = CMTime.zero
        var list: [Entry] = []
        for url in urls {
            let f = try AVAudioFile(forReading: url)
            let entry = Entry(url: url, sampleRate: f.processingFormat.sampleRate, frames: f.length, start: offset)
            list.append(entry)
            offset = CMTimeAdd(offset, entry.duration)
        }
        entries = list
        totalDuration = offset.seconds
    }

    public var trackCount: Int { entries.count }

    /// Timeline position of the end of the last buffer handed out.
    public var lastEnqueuedEnd: TimeInterval {
        lock.lock(); defer { lock.unlock() }
        return enqueuedEnd.seconds
    }

    /// Start time on the shared timeline of track `i`.
    public func startOfTrack(_ i: Int) -> TimeInterval { entries.indices.contains(i) ? entries[i].start.seconds : totalDuration }

    /// The next packaged buffer, or nil at the end of the last file.
    public func next() -> CMSampleBuffer? {
        lock.lock(); defer { lock.unlock() }
        while index < entries.count {
            let entry = entries[index]
            do {
                if file == nil {
                    file = try AVAudioFile(forReading: entry.url, commonFormat: .pcmFormatFloat32, interleaved: true)
                }
                guard let file else { return nil }
                let remaining = file.length - file.framePosition
                if remaining <= 0 { self.file = nil; index += 1; continue }
                let want = AVAudioFrameCount(min(AVAudioFramePosition(Self.chunkSeconds * entry.sampleRate), remaining))
                guard let pcm = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: want) else { return nil }
                let position = file.framePosition
                try file.read(into: pcm, frameCount: want)
                if pcm.frameLength == 0 { self.file = nil; index += 1; continue }
                let local = CMTime(value: position, timescale: CMTimeScale(entry.sampleRate))
                let pts = CMTimeAdd(entry.start, local)
                let sample = try SampleBufferPackager.make(from: pcm, presentationTime: pts)
                enqueuedEnd = CMTimeAdd(pts, CMTime(value: CMTimeValue(pcm.frameLength), timescale: CMTimeScale(entry.sampleRate)))
                return sample
            } catch {
                self.file = nil
                index += 1
            }
        }
        return nil
    }

    /// Repositions so the next buffer starts at (or just before) `time` on the shared timeline.
    public func seek(to time: TimeInterval) {
        lock.lock(); defer { lock.unlock() }
        let t = Swift.max(0, time)
        var target = Swift.max(0, entries.count - 1)
        for (i, e) in entries.enumerated() where t >= e.start.seconds && t < CMTimeAdd(e.start, e.duration).seconds {
            target = i
            break
        }
        guard entries.indices.contains(target) else { return }
        index = target
        let e = entries[target]
        file = try? AVAudioFile(forReading: e.url, commonFormat: .pcmFormatFloat32, interleaved: true)
        let local = AVAudioFramePosition(Swift.max(0, t - e.start.seconds) * e.sampleRate)
        file?.framePosition = Swift.min(local, e.frames)
        enqueuedEnd = CMTimeAdd(e.start, CMTime(value: file?.framePosition ?? 0, timescale: CMTimeScale(e.sampleRate)))
    }
}

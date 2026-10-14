import AVFoundation
import Foundation

/// The tick file: a quiet 220 Hz tone on both channels plus a 20 ms 2 kHz tick on the left channel at every
/// integer second, so multi-room sync, clock-vs-ear and tap latency can be judged by ear and by the screen flash.
public enum TestTone {
    public static func write(to url: URL, seconds: Int = 120, rate: Double = 48_000) throws {
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 2, interleaved: false)!
        try? FileManager.default.removeItem(at: url)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: rate, AVNumberOfChannelsKey: 2,
            AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true, AVLinearPCMIsBigEndianKey: false,
        ]
        let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        let perSecond = Int(rate)
        let tickFrames = Int(rate * 0.02)
        for _ in 0..<seconds {
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(perSecond)) else { break }
            buffer.frameLength = AVAudioFrameCount(perSecond)
            let left = buffer.floatChannelData![0]
            let right = buffer.floatChannelData![1]
            for i in 0..<perSecond {
                let t = Double(i) / rate
                let tone = Float(0.1 * sin(2 * .pi * 220 * t))
                right[i] = tone
                // The tone is continuous across seconds because 220 Hz has a whole number of cycles per second.
                left[i] = i < tickFrames ? tone + Float(0.8 * sin(2 * .pi * 2000 * t)) : tone
            }
            try file.write(from: buffer)
        }
    }
}

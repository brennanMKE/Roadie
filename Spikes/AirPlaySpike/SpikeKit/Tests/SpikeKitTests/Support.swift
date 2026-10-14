import AVFoundation
import Foundation
@testable import SpikeKit

/// Writes a ramp file to a temp dir (never played): `seconds` long, every channel a rising ramp.
func writeRampFile(seconds: Double, rate: Double, channels: AVAudioChannelCount = 2) throws -> URL {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("SpikeKitTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let url = dir.appendingPathComponent("ramp-\(Int(rate)).wav")
    let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: channels, interleaved: false)!
    let settings: [String: Any] = [
        AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: rate, AVNumberOfChannelsKey: Int(channels),
        AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true, AVLinearPCMIsBigEndianKey: false,
    ]
    let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
    let frames = AVAudioFrameCount(seconds * rate)
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
    buffer.frameLength = frames
    for c in 0..<Int(channels) {
        for i in 0..<Int(frames) { buffer.floatChannelData![c][i] = Float(i) / Float(frames) * 0.5 }
    }
    try file.write(from: buffer)
    return url
}

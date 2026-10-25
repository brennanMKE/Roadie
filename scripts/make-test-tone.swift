#!/usr/bin/env swift
// make-test-tone.swift — the Swift half of scripts/make-test-audio.sh (#0195). Host only, run once; the files it
// makes are committed under Packages/PlayerKit/Sources/PlayerKitTestFixtures/Audio/.
//
//   make-test-tone.swift <out.wav> <hz> <seconds>
//       44.1 kHz stereo 16-bit sine at amplitude 0.5 (the same shape as the tests' writeSine).
//   make-test-tone.swift --tag <in.m4a> <out.m4a> <title> <artist> <album> <track> <year>
//       copies an afconvert-made m4a (AAC or ALAC) without re-encoding and adds iTunes-style tags.
//   make-test-tone.swift --jpeg <out.jpg> [size]
//       a one-colour JPEG (default 64 px), the tests' writeJPEG.

import AVFoundation
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

func writeTone(_ url: URL, hz: Double, seconds: Double) throws {
    let rate = 44_100.0
    let settings: [String: Any] = [
        AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: rate, AVNumberOfChannelsKey: 2, AVLinearPCMBitDepthKey: 16,
    ]
    let file = try AVAudioFile(forWriting: url, settings: settings)
    let frames = AVAudioFrameCount(rate * seconds)
    let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frames)!
    buffer.frameLength = frames
    for ch in 0..<2 {
        let data = buffer.floatChannelData![ch]
        for i in 0..<Int(frames) { data[i] = Float(0.5 * sin(2 * .pi * hz * Double(i) / rate)) }
    }
    try file.write(from: buffer)
}

func item(_ id: AVMetadataIdentifier, _ value: NSCopying & NSObjectProtocol) -> AVMetadataItem {
    let item = AVMutableMetadataItem()
    item.identifier = id
    item.value = value
    item.extendedLanguageTag = "und"
    return item
}

func tag(_ input: URL, _ output: URL, title: String, artist: String, album: String, track: Int, year: String) async throws {
    // trkn: 2 bytes padding, track, total, 2 bytes padding (big-endian 16-bit).
    let trkn = Data([0, 0, 0, UInt8(track), 0, 0, 0, 0])
    let number = AVMutableMetadataItem()
    number.identifier = .iTunesMetadataTrackNumber
    number.value = trkn as NSData
    number.dataType = kCMMetadataBaseDataType_RawData as String
    let items = [
        item(.iTunesMetadataSongName, title as NSString), item(.iTunesMetadataArtist, artist as NSString),
        item(.iTunesMetadataAlbum, album as NSString), item(.iTunesMetadataReleaseDate, year as NSString), number,
    ]
    try? FileManager.default.removeItem(at: output)
    guard let session = AVAssetExportSession(asset: AVURLAsset(url: input), presetName: AVAssetExportPresetPassthrough)
    else { fail("no passthrough export session for \(input.path)") }
    session.metadata = items
    try await session.export(to: output, as: .m4a)
}

func writeJPEG(_ url: URL, size: Int) throws {
    let context = CGContext(
        data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    context.setFillColor(CGColor(red: 0.8, green: 0.2, blue: 0.1, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: size, height: size))
    let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, context.makeImage()!, nil)
    guard CGImageDestinationFinalize(destination) else { fail("could not write \(url.path)") }
}

let args = Array(CommandLine.arguments.dropFirst())
do {
    switch args.first {
    case "--tag":
        guard args.count == 8, let track = Int(args[6]) else { fail("usage: --tag <in> <out> <title> <artist> <album> <track> <year>") }
        try await tag(
            URL(filePath: args[1]), URL(filePath: args[2]), title: args[3], artist: args[4], album: args[5], track: track,
            year: args[7])
    case "--jpeg":
        guard args.count >= 2 else { fail("usage: --jpeg <out.jpg> [size]") }
        try writeJPEG(URL(filePath: args[1]), size: args.count > 2 ? Int(args[2]) ?? 64 : 64)
    default:
        guard args.count == 3, let hz = Double(args[1]), let seconds = Double(args[2]) else {
            fail("usage: make-test-tone.swift <out.wav> <hz> <seconds> | --tag … | --jpeg …")
        }
        try writeTone(URL(filePath: args[0]), hz: hz, seconds: seconds)
    }
} catch {
    fail("make-test-tone: \(error)")
}

import AVFoundation
import Foundation
import UniformTypeIdentifiers
import os

public struct SkippedFile: Sendable {
    public let url: URL
    public let reason: String
}

public struct LocalImport: Sendable {
    public var tracks: [Track]
    public var skipped: [SkippedFile]
}

/// Turns files and folders chosen by the user into `Track`s. Never throws from `load`;
/// files that cannot be opened are reported in `LocalImport.skipped` and logged.
public enum LocalTrackLoader {
    private static let logger = Logger(subsystem: "com.brennanmke.SkinAmp", category: "LocalTrackLoader")
    private static let maxConcurrent = 4

    public static let audioTypes: [UTType] = [
        .audio, .mp3, .mpeg4Audio, .wav, .aiff, UTType(filenameExtension: "flac"),
    ].compactMap { $0 }

    /// M3U, M3U8 and PLS, for open panels. `load` expands these in place.
    public static let playlistTypes: [UTType] = ["m3u", "m3u8", "pls"].compactMap {
        UTType(filenameExtension: $0, conformingTo: .data)
    }

    public static func isAudio(_ url: URL) -> Bool {
        if let type = try? url.resourceValues(forKeys: [.contentTypeKey]).contentType {
            return type.conforms(to: .audio)
        }
        return UTType(filenameExtension: url.pathExtension)?.conforms(to: .audio) == true
    }

    /// Expands folders (recursively, Finder order, files before subfolders); input order is kept.
    /// Explicitly given files are kept whatever their type so `load` can report them.
    public static func collectAudioURLs(from urls: [URL]) -> [URL] {
        var result: [URL] = []
        for url in urls {
            if isDirectory(url) {
                walk(url, into: &result)
            } else {
                result.append(url)
            }
        }
        return result
    }

    public static func load(_ urls: [URL]) async -> LocalImport {
        let expanded = expandPlaylists(urls)
        let all = collectAudioURLs(from: expanded.urls)
        var tracks: [Track?] = Array(repeating: nil, count: all.count)
        var skipped: [Int: SkippedFile] = [:]

        func skip(_ index: Int, _ reason: String) {
            let url = all[index]
            logger.warning("Skipping \(url.lastPathComponent, privacy: .public): \(reason, privacy: .public)")
            skipped[index] = SkippedFile(url: url, reason: reason)
        }

        var candidates: [Int] = []
        for (index, url) in all.enumerated() {
            if !FileManager.default.fileExists(atPath: url.path) {
                skip(index, "file not found")
            } else if !isAudio(url) {
                skip(index, "not an audio file")
            } else {
                candidates.append(index)
            }
        }

        await withTaskGroup(of: (Int, Result<Track, any Error>).self) { group in
            var next = 0
            func addNext() {
                guard next < candidates.count else { return }
                let index = candidates[next]
                let url = all[index]
                next += 1
                group.addTask { (index, await Result { try await loadTrack(at: url) }) }
            }
            for _ in 0..<maxConcurrent { addNext() }
            while let (index, result) = await group.next() {
                switch result {
                case .success(let track): tracks[index] = track
                case .failure(let error): skip(index, error.localizedDescription)
                }
                addNext()
            }
        }

        let loaded = tracks.compactMap { $0 }
        let skippedList = expanded.skipped + skipped.keys.sorted().compactMap { skipped[$0] }
        logger.info("Imported \(loaded.count) track(s), skipped \(skippedList.count)")
        return LocalImport(tracks: loaded, skipped: skippedList)
    }

    public static func loadTrack(at url: URL) async throws -> Track {
        // Opening with AVAudioFile is the playable check: the player uses the same API.
        let sampleRate: Double
        let channels: Int
        let fileDuration: TimeInterval
        do {
            let file = try AVAudioFile(forReading: url)
            sampleRate = file.fileFormat.sampleRate
            channels = Int(file.fileFormat.channelCount)
            fileDuration = sampleRate > 0 ? Double(file.length) / sampleRate : 0
        }

        var title: String?
        var artist: String?
        var album: String?
        var duration = fileDuration
        var bitrate: Int?

        let asset = AVURLAsset(url: url)
        do {
            let (cmDuration, common) = try await asset.load(.duration, .commonMetadata)
            let seconds = CMTimeGetSeconds(cmDuration)
            if cmDuration.isNumeric, seconds.isFinite, seconds > 0 { duration = seconds }
            title = await stringValue(common, .commonIdentifierTitle)
            artist = await stringValue(common, .commonIdentifierArtist)
            album = await stringValue(common, .commonIdentifierAlbumName)
            if let track = try await asset.loadTracks(withMediaType: .audio).first {
                let rate = try await track.load(.estimatedDataRate)
                if rate.isFinite, rate > 0 { bitrate = Int((Double(rate) / 1000).rounded()) }
            }
        } catch {
            logger.debug("Metadata unavailable for \(url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }

        if bitrate == nil, duration > 0,
           let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize {
            bitrate = Int((Double(size) * 8 / duration / 1000).rounded())
        }

        return Track(
            title: title ?? url.deletingPathExtension().lastPathComponent,
            artist: artist ?? "",
            album: album,
            duration: duration,
            bitrate: bitrate,
            sampleRate: sampleRate,
            channels: channels,
            source: .file(url)
        )
    }

    // MARK: Private

    /// Replaces each explicitly given playlist file with its entries, at its position. Entries that are playlists
    /// themselves, streams, and unreadable playlists are reported as skipped.
    private static func expandPlaylists(_ urls: [URL]) -> (urls: [URL], skipped: [SkippedFile]) {
        var result: [URL] = []
        var skipped: [SkippedFile] = []
        func skip(_ url: URL, _ reason: String) {
            logger.warning("Skipping \(url.lastPathComponent, privacy: .public): \(reason, privacy: .public)")
            skipped.append(SkippedFile(url: url, reason: reason))
        }
        for url in urls {
            guard PlaylistFile.isPlaylist(url), !isDirectory(url) else {
                result.append(url)
                continue
            }
            guard let data = try? Data(contentsOf: url) else {
                skip(url, "could not read playlist")
                continue
            }
            let format = PlaylistFile.format(for: url, data: data)
            let entries = PlaylistFile.parse(data, format: format, pathExtension: url.pathExtension)
            logger.info("Playlist \(url.lastPathComponent, privacy: .public): \(entries.count) entries")
            for entry in entries {
                switch PlaylistFile.resolve(entry, relativeTo: url) {
                case .file(let file): result.append(file)
                case .skip(let location, let reason): skip(url.deletingLastPathComponent().appending(path: location), reason)
                }
            }
        }
        return (result, skipped)
    }

    private static func stringValue(_ items: [AVMetadataItem], _ id: AVMetadataIdentifier) async -> String? {
        guard let item = AVMetadataItem.metadataItems(from: items, filteredByIdentifier: id).first,
              let value = try? await item.load(.stringValue) else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func isDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
    }

    private static func walk(_ directory: URL, into result: inout [URL]) {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            logger.warning("Cannot read folder \(directory.lastPathComponent, privacy: .public)")
            return
        }
        let sorted = entries.sorted {
            $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending
        }
        var folders: [URL] = []
        for entry in sorted {
            if isDirectory(entry) {
                folders.append(entry)
            } else if isAudio(entry) {
                result.append(entry)
            }
        }
        for folder in folders { walk(folder, into: &result) }
    }
}

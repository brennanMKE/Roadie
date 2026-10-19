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
    /// Title and duration a playlist entry gives for a track (`#EXTINF`, PLS `TitleN`/`LengthN`).
    public struct PlaylistHint: Equatable, Sendable {
        public var title: String?
        public var duration: Int?

        public init(title: String?, duration: Int?) {
            self.title = title
            self.duration = duration
        }
    }

    private static let logger = Logger(subsystem: "com.brennanmke.SkinAmp", category: "LocalTrackLoader")
    private static let maxConcurrent = 4
    private static let maxPlaylistDepth = 8

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
        var all: [URL] = []
        var hints: [Int: PlaylistHint] = [:]
        for item in expanded.items {
            if let hint = item.hint, !isDirectory(item.url) {
                hints[all.count] = hint
                all.append(item.url)
            } else {
                all += collectAudioURLs(from: [item.url])
            }
        }
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
                let hint = hints[index]
                next += 1
                group.addTask { (index, await Result { try await loadTrack(at: url, hint: hint) }) }
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

    public static func loadTrack(at url: URL, hint: PlaylistHint? = nil) async throws -> Track {
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

        (title, artist, duration) = applyingPlaylistHint(hint, title: title, artist: artist, duration: duration)

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

    /// Fills a missing title tag (and artist, split on the first " - ") and an unknown duration from a playlist entry.
    /// Embedded tags and a known file duration win.
    static func applyingPlaylistHint(
        _ hint: PlaylistHint?, title: String?, artist: String?, duration: TimeInterval
    ) -> (title: String?, artist: String?, duration: TimeInterval) {
        var title = title
        var artist = artist
        var duration = duration
        if title == nil, let text = hint?.title?.trimmingCharacters(in: .whitespaces), !text.isEmpty {
            var hintTitle = text
            var hintArtist: String?
            if let range = text.range(of: " - ") {
                let before = text[..<range.lowerBound].trimmingCharacters(in: .whitespaces)
                let after = text[range.upperBound...].trimmingCharacters(in: .whitespaces)
                if !before.isEmpty, !after.isEmpty {
                    hintArtist = before
                    hintTitle = after
                }
            }
            title = hintTitle
            if artist == nil { artist = hintArtist }
        }
        if !(duration.isFinite && duration > 0), let seconds = hint?.duration, seconds > 0 {
            duration = TimeInterval(seconds)
        }
        return (title, artist, duration)
    }

    // MARK: Private

    /// Replaces each explicitly given playlist file with its entries, at its position. Entries that are playlists
    /// themselves are expanded in place, relative to their own folder, up to 8 levels deep. Cycles, deeper nesting,
    /// streams and unreadable playlists are reported as skipped. Each track from a playlist carries the title and
    /// duration of the entry that lists it (the innermost playlist); URLs given directly carry no hint.
    private static func expandPlaylists(_ urls: [URL]) -> (items: [(url: URL, hint: PlaylistHint?)], skipped: [SkippedFile]) {
        var result: [(url: URL, hint: PlaylistHint?)] = []
        var skipped: [SkippedFile] = []
        func skip(_ url: URL, _ reason: String) {
            logger.warning("Skipping \(url.lastPathComponent, privacy: .public): \(reason, privacy: .public)")
            skipped.append(SkippedFile(url: url, reason: reason))
        }
        func expand(_ playlist: URL, depth: Int, ancestors: Set<String>) {
            let key = playlist.standardizedFileURL.resolvingSymlinksInPath().path
            if ancestors.contains(key) {
                skip(playlist, "playlist cycle")
                return
            }
            if depth > maxPlaylistDepth {
                skip(playlist, "playlists nested too deeply")
                return
            }
            guard let data = try? Data(contentsOf: playlist) else {
                skip(playlist, "could not read playlist")
                return
            }
            let format = PlaylistFile.format(for: playlist, data: data)
            let entries = PlaylistFile.parse(data, format: format, pathExtension: playlist.pathExtension)
            logger.info("Playlist \(playlist.lastPathComponent, privacy: .public): \(entries.count) entries")
            for entry in entries {
                switch PlaylistFile.resolve(entry, relativeTo: playlist) {
                case .file(let file) where PlaylistFile.isPlaylist(file) && !isDirectory(file):
                    expand(file, depth: depth + 1, ancestors: ancestors.union([key]))
                case .file(let file):
                    result.append((file, PlaylistHint(title: entry.title, duration: entry.duration)))
                case .skip(let location, let reason):
                    skip(playlist.deletingLastPathComponent().appending(path: location), reason)
                }
            }
        }
        for url in urls {
            guard PlaylistFile.isPlaylist(url), !isDirectory(url) else {
                result.append((url, nil))
                continue
            }
            expand(url, depth: 1, ancestors: [])
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

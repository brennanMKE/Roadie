import CryptoKit
import Foundation

public enum MuseumDownloadResult: Hashable, Sendable {
    /// A new file, moved into `<folder>/Museum/`.
    case added(URL)
    /// The same bytes were already on disk (indexed elsewhere, or at the target name); nothing was written.
    case alreadyHad(URL)

    public var url: URL {
        switch self {
        case .added(let url), .alreadyHad(let url): url
        }
    }
}

/// Lets the browser model swap in a stub.
public protocol MuseumDownloading: Sendable {
    func download(
        _ skin: MuseumSkin, into folder: URL, existing: @escaping @Sendable (String) async throws -> URL?
    ) async throws -> MuseumDownloadResult
}

/// Downloads a skin into `<skins folder>/Museum/`: fetched into the hidden `Museum/.partial/`, then size-, md5- and
/// duplicate-checked, then moved into place under a sanitized name. The partial file never survives a failure.
public struct MuseumDownloader: MuseumDownloading {
    public static let folderName = "Museum"
    public static let partialFolderName = ".partial"
    public static let defaultMaxBytes = 16 * 1024 * 1024

    private let transport: any MuseumTransport
    private let maxBytes: Int
    private let userAgent: String?

    public init(transport: any MuseumTransport, maxBytes: Int = MuseumDownloader.defaultMaxBytes, userAgent: String? = nil) {
        self.transport = transport
        self.maxBytes = maxBytes
        self.userAgent = userAgent
    }

    /// `existing` maps a SHA-256 to the file already indexed with those bytes, if any.
    public func download(
        _ skin: MuseumSkin, into folder: URL, existing: @escaping @Sendable (String) async throws -> URL?
    ) async throws -> MuseumDownloadResult {
        guard skin.isAcceptable else { throw MuseumError.decoding }
        let fm = FileManager.default
        let museum = folder.appendingPathComponent(Self.folderName, isDirectory: true)
        let partialDir = museum.appendingPathComponent(Self.partialFolderName, isDirectory: true)
        try fm.createDirectory(at: partialDir, withIntermediateDirectories: true)
        let partial = partialDir.appendingPathComponent("\(UUID().uuidString).wsz")
        defer { try? fm.removeItem(at: partial) }

        var request = URLRequest(url: skin.downloadURL)
        request.httpMethod = "GET"
        request.timeoutInterval = 30
        if let userAgent { request.setValue(userAgent, forHTTPHeaderField: "User-Agent") }
        let data: Data
        let response: HTTPURLResponse
        do {
            (data, response) = try await transport.send(request)
        } catch is URLError {
            throw MuseumError.offline
        }
        guard (200..<300).contains(response.statusCode) else { throw MuseumError.http(response.statusCode) }
        try data.write(to: partial, options: .atomic)

        guard data.count <= maxBytes else { throw MuseumError.tooLarge }
        let md5 = Insecure.MD5.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard md5 == skin.md5.lowercased() else { throw MuseumError.checksumMismatch }
        let sha256 = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        if let had = try await existing(sha256), fm.fileExists(atPath: had.path) { return .alreadyHad(had) }

        let base = Self.sanitizedFilename(skin.filename, fallback: skin.md5)
        let stem = (base as NSString).deletingPathExtension
        var suffix = 1
        while true {
            let name = suffix == 1 ? base : "\(stem)-\(suffix).wsz"
            let target = museum.appendingPathComponent(name)
            if fm.fileExists(atPath: target.path) {
                if (try? Data(contentsOf: target)) == data { return .alreadyHad(target) }
                suffix += 1
                continue
            }
            do {
                try fm.moveItem(at: partial, to: target)
            } catch CocoaError.fileWriteFileExists {
                suffix += 1
                continue
            }
            return .added(target)
        }
    }

    /// A single path component ending in `.wsz`: separators and leading dots removed; `fallback` when nothing is left.
    public static func sanitizedFilename(_ name: String, fallback: String) -> String {
        var cleaned = String(name.map { $0 == "/" || $0 == "\\" || $0 == ":" || $0.isNewline ? "_" : $0 })
        cleaned = cleaned.trimmingCharacters(in: .whitespaces)
        while cleaned.hasPrefix(".") || cleaned.hasPrefix("_") { cleaned.removeFirst() }
        var stem = cleaned
        if stem.lowercased().hasSuffix(".wsz") { stem = String(stem.dropLast(4)) }
        stem = stem.trimmingCharacters(in: .whitespaces)
        if stem.isEmpty || stem.allSatisfy({ $0 == "." || $0 == "_" }) { stem = fallback }
        return String(stem.prefix(200)) + ".wsz"
    }
}

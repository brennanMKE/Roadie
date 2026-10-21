import CryptoKit
import Foundation
import Testing

@testable import SkinMuseum

/// Answers every GET with fixed bytes (or a failure). Never touches the network.
private final class BytesTransport: MuseumTransport, @unchecked Sendable {
    private let lock = NSLock()
    private let bytes: Data
    private let failure: URLError.Code?
    private var count = 0
    init(_ bytes: Data, failure: URLError.Code? = nil) {
        self.bytes = bytes
        self.failure = failure
    }
    var calls: Int { lock.withLock { count } }
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        lock.withLock { count += 1 }
        if let failure { throw URLError(failure) }
        return (bytes, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!)
    }
}

private func md5(_ data: Data) -> String { Insecure.MD5.hash(data: data).map { String(format: "%02x", $0) }.joined() }
private func sha256(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

/// Synthetic skin bytes (the downloader never parses the archive, so any bytes stand in for a .wsz).
private func skinBytes(_ seed: UInt8 = 1, count: Int = 2048) -> Data {
    Data((0..<count).map { UInt8(truncatingIfNeeded: $0) &+ seed })
}

private func museumSkin(_ data: Data, filename: String = "Cool_Skin_[S123].wsz", md5 override: String? = nil) -> MuseumSkin {
    let hash = override ?? md5(data)
    return MuseumSkin(
        md5: hash, filename: filename,
        screenshotURL: URL(string: "https://r2.webampskins.org/screenshots/\(hash).png")!,
        downloadURL: URL(string: "https://r2.webampskins.org/skins/\(hash).wsz")!,
        museumURL: URL(string: "https://skins.webamp.org/skin/\(hash)")!, nsfw: false)
}

private let none: @Sendable (String) async throws -> URL? = { _ in nil }

private func partialFiles(_ folder: URL) -> [String] {
    let dir = folder.appendingPathComponent("Museum/.partial")
    return (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
}

@Suite struct MuseumDownloaderTests {
    @Test func downloadWritesVerifiedFileIntoMuseumFolder() async throws {
        let folder = try makeTempDirectory()
        let data = skinBytes()
        let result = try await MuseumDownloader(transport: BytesTransport(data)).download(
            museumSkin(data), into: folder, existing: none)
        let expected = folder.appendingPathComponent("Museum/Cool_Skin_[S123].wsz")
        #expect(result == .added(expected))
        #expect(try Data(contentsOf: expected) == data)
        #expect(partialFiles(folder).isEmpty)
    }

    @Test func md5MismatchDeletesAndThrows() async throws {
        let folder = try makeTempDirectory()
        let data = skinBytes()
        let skin = museumSkin(data, md5: String(repeating: "a", count: 32))
        await #expect(throws: MuseumError.checksumMismatch) {
            try await MuseumDownloader(transport: BytesTransport(data)).download(skin, into: folder, existing: none)
        }
        let museum = try FileManager.default.contentsOfDirectory(atPath: folder.appendingPathComponent("Museum").path)
        #expect(museum == [".partial"])
        #expect(partialFiles(folder).isEmpty)
    }

    @Test func oversizeDownloadIsRejected() async throws {
        let folder = try makeTempDirectory()
        let data = skinBytes(count: 4096)
        await #expect(throws: MuseumError.tooLarge) {
            try await MuseumDownloader(transport: BytesTransport(data), maxBytes: 1024).download(
                museumSkin(data), into: folder, existing: none)
        }
        #expect(partialFiles(folder).isEmpty)
    }

    @Test func alreadyIndexedSHA256ReusesExistingFile() async throws {
        let folder = try makeTempDirectory()
        let data = skinBytes()
        let had = folder.appendingPathComponent("Old/Cool.wsz")
        try FileManager.default.createDirectory(at: had.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: had)
        let wanted = sha256(data)
        let result = try await MuseumDownloader(transport: BytesTransport(data)).download(
            museumSkin(data), into: folder, existing: { $0 == wanted ? had : nil })
        #expect(result == .alreadyHad(had))
        let museum = try FileManager.default.contentsOfDirectory(atPath: folder.appendingPathComponent("Museum").path)
        #expect(museum == [".partial"])
        #expect(partialFiles(folder).isEmpty)
    }

    @Test func filenameIsSanitized() async throws {
        #expect(MuseumDownloader.sanitizedFilename("../x.wsz", fallback: "f") == "x.wsz")
        #expect(MuseumDownloader.sanitizedFilename(".hidden", fallback: "f") == "hidden.wsz")
        #expect(MuseumDownloader.sanitizedFilename("noext", fallback: "f") == "noext.wsz")
        #expect(MuseumDownloader.sanitizedFilename("a/b\\c.WSZ", fallback: "f") == "a_b_c.wsz")
        #expect(MuseumDownloader.sanitizedFilename("..", fallback: "f") == "f.wsz")

        let folder = try makeTempDirectory()
        let data = skinBytes()
        let result = try await MuseumDownloader(transport: BytesTransport(data)).download(
            museumSkin(data, filename: "../../evil.wsz"), into: folder, existing: none)
        #expect(result == .added(folder.appendingPathComponent("Museum/evil.wsz")))
    }

    @Test func collidingNameWithDifferentBytesGetsSuffix() async throws {
        let folder = try makeTempDirectory()
        let museum = folder.appendingPathComponent("Museum")
        try FileManager.default.createDirectory(at: museum, withIntermediateDirectories: true)
        try skinBytes(9).write(to: museum.appendingPathComponent("Cool_Skin_[S123].wsz"))
        let data = skinBytes()
        let result = try await MuseumDownloader(transport: BytesTransport(data)).download(
            museumSkin(data), into: folder, existing: none)
        #expect(result == .added(museum.appendingPathComponent("Cool_Skin_[S123]-2.wsz")))

        // Same bytes at the target name: reused, not copied.
        let again = try await MuseumDownloader(transport: BytesTransport(data)).download(
            museumSkin(data), into: folder, existing: none)
        #expect(again == .alreadyHad(museum.appendingPathComponent("Cool_Skin_[S123]-2.wsz")))
    }

    @Test func partialFileIsRemovedOnFailure() async throws {
        let folder = try makeTempDirectory()
        let data = skinBytes()
        await #expect(throws: MuseumError.offline) {
            try await MuseumDownloader(transport: BytesTransport(data, failure: .notConnectedToInternet)).download(
                museumSkin(data), into: folder, existing: none)
        }
        #expect(partialFiles(folder).isEmpty)
        await #expect(throws: StubError.self) {
            try await MuseumDownloader(transport: BytesTransport(data)).download(
                museumSkin(data), into: folder, existing: { _ in throw StubError() })
        }
        #expect(partialFiles(folder).isEmpty)
    }
}

private struct StubError: Error {}

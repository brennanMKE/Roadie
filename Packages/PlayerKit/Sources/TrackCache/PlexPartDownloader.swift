import Foundation
import PlexKit

/// The one `CacheDownloader` that talks HTTP. The request is built by `PlexClient.request`, so the
/// token travels in a request header and never in a URL; this type holds no token itself.
public struct PlexPartDownloader: CacheDownloader, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    /// Built per download so Settings changes apply without restarting; nil means "no server set up".
    public typealias ClientProvider = @Sendable () throws -> PlexClient?

    private let clientProvider: ClientProvider
    private let session: URLSession

    public init(clientProvider: @escaping ClientProvider, session: URLSession = PlexPartDownloader.makeSession()) {
        self.clientProvider = clientProvider
        self.session = session
    }

    public var description: String { "PlexPartDownloader" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: []) }

    /// Ephemeral with no URL cache: Foundation's Cache.db must never hold a response body or the
    /// request that fetched it.
    public static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 600
        return URLSession(configuration: configuration)
    }

    /// The app's provider: the saved server selection, the token from `tokenStore`, the stored
    /// client identifier. Returns nil when the address is empty or there is no token (or the
    /// Keychain read is refused). Reads the Keychain on each call.
    public static func settingsClientProvider(
        defaults: UserDefaults = .standard,
        tokenStore: any PlexTokenStore = KeychainPlexTokenStore()
    ) -> ClientProvider {
        nonisolated(unsafe) let defaults = defaults
        return {
            guard let data = defaults.data(forKey: PlexSettingsModel.selectionDefaultsKey),
                  let selection = try? JSONDecoder().decode(PlexServerSelection.self, from: data),
                  !selection.address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  let token = try? tokenStore.load() else { return nil }
            return PlexClient(
                baseURL: try PlexAddress.normalize(selection.address), token: token,
                clientIdentifier: PlexClientIdentifier.stored(in: defaults))
        }
    }

    public func download(partKey: String, to fileURL: URL, progress: @escaping @Sendable (Int64) -> Void) async throws -> Int64 {
        guard let client = try clientProvider() else { throw TrackCacheError.noServer }
        var request = client.request(path: partKey)
        // A part is a file, not JSON. The token header stays.
        request.setValue("*/*", forHTTPHeaderField: "Accept")

        do {
            let (bytes, response) = try await session.bytes(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw TrackCacheError.download(.transport(.badServerResponse))
            }
            switch http.statusCode {
            case 200..<300: break
            case 401: throw TrackCacheError.download(.unauthorized)
            case 404: throw TrackCacheError.download(.notFound)
            default: throw TrackCacheError.download(.httpStatus(http.statusCode))
            }
            return try await write(bytes, to: fileURL, progress: progress)
        } catch let error as URLError {
            if error.code == .cancelled { throw CancellationError() }
            throw TrackCacheError.download(.transport(error.code))
        }
    }

    /// One byte range of a part, for a progressive reader's far jump (an `moov` atom at the end of an m4a, an
    /// ID3v1 tag). The token travels in the header like every other request; the range is never written to disk.
    public func fetch(partKey: String, range: Range<Int64>) async throws -> Data {
        guard !range.isEmpty, let client = try clientProvider() else { throw TrackCacheError.noServer }
        var request = client.request(path: partKey)
        request.setValue("*/*", forHTTPHeaderField: "Accept")
        request.setValue("bytes=\(range.lowerBound)-\(range.upperBound - 1)", forHTTPHeaderField: "Range")
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw TrackCacheError.download(.transport(.badServerResponse))
            }
            switch http.statusCode {
            case 206:
                guard Int64(data.count) == range.count else { throw TrackCacheError.download(.transport(.badServerResponse)) }
                return data
            case 200:
                // The server ignored the range and sent the whole part: keep the slice.
                guard Int64(data.count) >= range.upperBound else { throw TrackCacheError.download(.transport(.badServerResponse)) }
                return data.subdata(in: Int(range.lowerBound)..<Int(range.upperBound))
            case 401: throw TrackCacheError.download(.unauthorized)
            case 404: throw TrackCacheError.download(.notFound)
            default: throw TrackCacheError.download(.httpStatus(http.statusCode))
            }
        } catch let error as URLError {
            if error.code == .cancelled { throw CancellationError() }
            throw TrackCacheError.download(.transport(error.code))
        }
    }

    private func write(_ bytes: URLSession.AsyncBytes, to fileURL: URL, progress: @Sendable (Int64) -> Void) async throws -> Int64 {
        let handle: FileHandle
        do { handle = try FileHandle(forWritingTo: fileURL) } catch {
            throw TrackCacheError.io(error.localizedDescription)
        }
        defer { try? handle.close() }
        let chunk = 256 * 1024
        var buffer = [UInt8]()
        buffer.reserveCapacity(chunk)
        var total: Int64 = 0
        func flush() throws {
            guard !buffer.isEmpty else { return }
            do { try handle.write(contentsOf: buffer) } catch { throw TrackCacheError.io(error.localizedDescription) }
            total += Int64(buffer.count)
            buffer.removeAll(keepingCapacity: true)
            progress(total)
        }
        for try await byte in bytes {
            buffer.append(byte)
            if buffer.count >= chunk { try flush() }
        }
        try Task.checkCancellation()
        try flush()
        do { try handle.close() } catch { throw TrackCacheError.io(error.localizedDescription) }
        return total
    }
}

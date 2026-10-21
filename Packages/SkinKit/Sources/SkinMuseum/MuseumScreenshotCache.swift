import Foundation

/// Museum screenshots: an in-memory LRU of PNG data over a disk LRU (`{md5}.png`, evicted by access date).
/// Fetches go through `MuseumTransport`, at most `maxConcurrentFetches` at once, de-duplicated by md5.
public actor MuseumScreenshotCache {
    private let directory: URL
    private let transport: any MuseumTransport
    private let userAgent: String
    private let maxDiskBytes: Int
    private let maxMemoryEntries: Int
    private let maxConcurrentFetches: Int
    private let now: @Sendable () -> Date
    private let fileManager = FileManager.default

    private var memory: [String: Data] = [:]
    private var memoryOrder: [String] = []
    private var inFlight: [String: Task<Data, Error>] = [:]
    private var activeFetches = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    public init(
        directory: URL, transport: any MuseumTransport, userAgent: String,
        maxDiskBytes: Int = 200 * 1024 * 1024, maxMemoryEntries: Int = 300, maxConcurrentFetches: Int = 4,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.directory = directory
        self.transport = transport
        self.userAgent = userAgent
        self.maxDiskBytes = maxDiskBytes
        self.maxMemoryEntries = maxMemoryEntries
        self.maxConcurrentFetches = maxConcurrentFetches
        self.now = now
    }

    /// The disk path for `md5`, or nil unless it's a valid 32-hex md5.
    public func fileURL(for md5: String) -> URL? {
        guard MuseumSkin.isValidMD5(md5) else { return nil }
        return directory.appendingPathComponent("\(md5).png")
    }

    public func screenshot(for skin: MuseumSkin) async throws -> Data {
        try await screenshot(md5: skin.md5, url: skin.screenshotURL)
    }

    public func screenshot(md5: String, url: URL) async throws -> Data {
        guard let path = fileURL(for: md5) else { throw MuseumError.decoding }
        if let data = memory[md5] {
            touchMemory(md5)
            try? fileManager.setAttributes([.modificationDate: now()], ofItemAtPath: path.path)
            return data
        }
        if let data = try? Data(contentsOf: path) {
            try? fileManager.setAttributes([.modificationDate: now()], ofItemAtPath: path.path)
            remember(md5, data)
            return data
        }
        if let task = inFlight[md5] { return try await task.value }
        let task = Task { try await self.fetch(url) }
        inFlight[md5] = task
        defer { inFlight[md5] = nil }
        let data = try await task.value
        store(data, at: path)
        remember(md5, data)
        return data
    }

    private func fetch(_ url: URL) async throws -> Data {
        guard url.scheme?.lowercased() == "https" else { throw MuseumError.decoding }
        await acquire()
        defer { release() }
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        let data: Data, response: HTTPURLResponse
        do {
            (data, response) = try await transport.send(request)
        } catch is URLError {
            throw MuseumError.offline
        }
        guard (200..<300).contains(response.statusCode) else { throw MuseumError.http(response.statusCode) }
        guard !data.isEmpty else { throw MuseumError.decoding }
        return data
    }

    private func acquire() async {
        if activeFetches < maxConcurrentFetches {
            activeFetches += 1
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    private func release() {
        if waiters.isEmpty {
            activeFetches -= 1
        } else {
            waiters.removeFirst().resume()  // The slot passes straight to the waiter.
        }
    }

    private func remember(_ md5: String, _ data: Data) {
        memory[md5] = data
        touchMemory(md5)
        while memoryOrder.count > maxMemoryEntries {
            memory[memoryOrder.removeFirst()] = nil
        }
    }

    private func touchMemory(_ md5: String) {
        memoryOrder.removeAll { $0 == md5 }
        memoryOrder.append(md5)
    }

    private func store(_ data: Data, at path: URL) {
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: path, options: .atomic)
            try fileManager.setAttributes([.modificationDate: now()], ofItemAtPath: path.path)
        } catch {
            return
        }
        evictDisk()
    }

    private func evictDisk() {
        let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey]
        guard let files = try? fileManager.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: keys, options: .skipsHiddenFiles)
        else { return }
        var entries = files.filter { $0.pathExtension == "png" }.map { url in
            let values = try? url.resourceValues(forKeys: Set(keys))
            return (url: url, date: values?.contentModificationDate ?? .distantPast, size: values?.fileSize ?? 0)
        }
        entries.sort { $0.date < $1.date }
        var total = entries.reduce(0) { $0 + $1.size }
        for entry in entries where total > maxDiskBytes {
            try? fileManager.removeItem(at: entry.url)
            total -= entry.size
        }
    }
}

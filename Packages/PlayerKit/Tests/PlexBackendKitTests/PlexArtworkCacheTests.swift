import CoreGraphics
import Foundation
import ImageIO
import MusicBackendKit
import MusicLibraryKit
import PlexKitStub
import Testing
@testable import PlexBackendKit

private func tinyPNG() -> Data {
    let context = CGContext(
        data: nil, width: 64, height: 64, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.setFillColor(CGColor(red: 0.5, green: 0.2, blue: 0.2, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
    let data = NSMutableData()
    let destination = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, context.makeImage()!, nil)
    CGImageDestinationFinalize(destination)
    return data as Data
}

@MainActor
@Suite struct PlexArtworkCacheTests {
    private let thumb = ArtworkRef("/library/metadata/3684/thumb/1791860628")

    @Test func plexArtworkIsFetchedAtThumbnailSizeWithTheTokenInTheHeader() async throws {
        let f = try BackendFixture()
        defer { f.cleanup() }
        try f.register([.init(path: "/photo/:/transcode", headers: ["Content-Type": "image/png"], body: tinyPNG())])
        try await f.backend.connect()
        let cache = ArtworkCache(backend: f.backend)
        #expect(await cache.image(for: thumb) != nil)
        #expect(await cache.image(for: thumb) != nil)
        let requests = f.handle.recorded.filter { $0.url.path == "/photo/:/transcode" }
        #expect(requests.count == 1)
        let request = try #require(requests.first)
        #expect(queryValue(request, "url") == "/library/metadata/3684/thumb/1791860628")
        #expect(queryValue(request, "width") == "200")
        #expect(queryValue(request, "height") == "200")
        #expect(header(request, "X-Plex-Token") == testSecret)
        #expect(f.handle.recorded.allSatisfy { !$0.url.absoluteString.contains(testSecret) })
        #expect(!String(reflecting: cache).contains(testSecret))
        #expect(!String(describing: await cache.statistics).contains(testSecret))
    }

    @Test func aMissingPlexThumbShowsThePlaceholderOnce() async throws {
        let f = try BackendFixture()
        defer { f.cleanup() }
        try f.register([.init(path: "/photo/:/transcode", status: 404)])
        try await f.backend.connect()
        let cache = ArtworkCache(backend: f.backend)
        #expect(await cache.image(for: thumb) == nil)
        #expect(await cache.image(for: thumb) == nil)
        #expect(f.handle.recorded.filter { $0.url.path == "/photo/:/transcode" }.count == 1)
    }
}

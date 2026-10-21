import Foundation

/// What the Museum browser needs from `MuseumClient`; tests use a stub.
public protocol MuseumPaging: Sendable {
    func page(_ query: MuseumQuery) async throws -> MuseumPage
    func cachedPage(_ query: MuseumQuery) async -> (page: MuseumPage, isStale: Bool)?
}

extension MuseumClient: MuseumPaging {}

/// PNG data for a skin's screenshot; `MuseumScreenshotCache` conforms.
public protocol MuseumScreenshotProviding: Sendable {
    func screenshot(for skin: MuseumSkin) async throws -> Data
}

extension MuseumScreenshotCache: MuseumScreenshotProviding {}

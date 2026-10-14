import AudioCore
import Foundation
import LocalPlayback
import PlexKit
import TrackCache

/// Everything the app needs to play Plex through AudioCore, built in the right order
/// (cache, resolver, player, pinner, backend). The app's composition root is the only place that names it.
@MainActor
public struct PlexPlaybackStack {
    public let cache: TrackCache
    public let player: Player
    /// Installed: keeps the current and next tracks pinned in the cache.
    public let pinner: CachePinner
    public let output: LocalPlayerOutput
    public let backend: PlexBackend

    /// Reads UserDefaults only. Never touches the Keychain or the network, and does not call `cache.prepare()`.
    public static func standard(
        defaults: UserDefaults = .standard,
        tokenStore: any PlexTokenStore = KeychainPlexTokenStore()
    ) -> PlexPlaybackStack {
        nonisolated(unsafe) let defaults = defaults
        let cache = TrackCache(
            directory: TrackCache.defaultDirectory(),
            limitBytes: CacheSettingsModel.storedLimit(in: defaults),
            downloader: PlexPartDownloader(
                clientProvider: PlexPartDownloader.settingsClientProvider(defaults: defaults, tokenStore: tokenStore)))
        let player = Player(resolver: PlexTrackResolver(cache: cache, savedMachineIdentifier: {
            // The saved server's identity; nil until a connection test has succeeded.
            defaults.data(forKey: PlexSettingsModel.selectionDefaultsKey)
                .flatMap { try? JSONDecoder().decode(PlexServerSelection.self, from: $0) }?
                .machineIdentifier
        }))
        let pinner = CachePinner(cache: cache, player: player)
        pinner.install()
        let output = LocalPlayerOutput(player: player)
        let backend = PlexBackend(
            settings: PlexBackend.settingsProvider(defaults: defaults, tokenStore: tokenStore),
            clientIdentifier: PlexClientIdentifier.stored(in: defaults), output: output)
        return PlexPlaybackStack(cache: cache, player: player, pinner: pinner, output: output, backend: backend)
    }
}

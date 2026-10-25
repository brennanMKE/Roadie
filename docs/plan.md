# Plan: Skinned player for a Music Assistant library

## Context

**2026-10-19 (#0074):** direct Plex support was removed. Music Assistant is the default source and reaches a Plex library through its own Plex provider; a local folder is the fallback. M2, the Plex parts of M3 and the progressive download in M7 are history; AudioCore's progressive player path stays as a generic seam.

The stub app (`App/`, `Packages/SkinKit`) loads classic `.wsz` skins and draws part of the
main window, but it plays nothing. The goal is to play music from the Plex server on joe
(`docs/plex-music-library.md`) through the skinned player, and to play local files as well.

Decisions made:
- **Playback:** download each Plex track to a local cache, then play it with the brief's
  `AVAudioEngine` graph. The cache is bounded and evicts the least recently used tracks (LRU).
  `AVAudioUnitEQ` and the analyzer tap work unchanged.
- **Sources:** Plex first. Local files go through the same queue and player.
- **Tracking:** local `issues/NNNN.md` files (issues skill), grouped by milestone.

Deliverables for this step, after approval: copy this plan to `docs/plan.md`, update
`docs/plex-music-library.md` to record the cache decision, then create the issues.

## Architecture

```
App/                      SwiftUI app; AppKit hosting for skinned windows
Packages/SkinKit/         (exists) skin parsing, sprites, skintool
Packages/PlayerKit/       new package
  AudioCore/              AVAudioEngine graph, EQ, analyzer, queue model
  MusicBackendKit/        source-neutral backend protocol and models
  LocalPlayback/          the "This Mac" output and LocalPlaybackStack
  FolderBackendKit/       a local folder as a backend (the fallback)
  MusicAssistantKit/      Music Assistant client and backend (the default source)
  LibraryBrowser/         browser view models and source switching
  MusicLibraryKit/        artwork cache
```

PlexKit and AudioCore have no UI code, and AudioCore does not know about Plex. They meet in
the queue: a `Track` has a title, artist, duration, an optional bitrate, sample rate and
channel count, and a source. A local track's source is a file URL. A Plex track's source
is a part key plus a cache key; `TrackCache` turns it into a local file before AudioCore
plays it.

### Playback (AudioCore)
- Graph: `AVAudioPlayerNode` → `AVAudioUnitEQ` (10 bands at 60/170/310/600/1k/3k/6k/12k/14k/16k Hz,
  plus a preamp through `globalGain`) → main mixer → output. Volume and balance go on the
  mixer; balance is the player node's `pan`.
- Plays a local `AVAudioFile`. The next track is scheduled on the player node before the
  current one ends, so there's no gap.
- Seek: stop the node, then schedule a segment from the target frame.
- Analyzer: a tap on the mixer feeds a `vDSP` FFT (spectrum) and raw samples (oscilloscope),
  drawn at 30–60 Hz.
- Media keys and Control Center through `MPRemoteCommandCenter` and `MPNowPlayingInfoCenter`.

### Track cache (TrackCache) (removed by #0074)
- **Location:** `~/Library/Caches/<bundle id>/Tracks/`. macOS may purge it when disk space
  runs low, which is acceptable.
- **Cache key:** server `machineIdentifier` + part id + the part's `updatedAt`. If the file
  changes on the server, the key changes. File extension comes from the part (`.mp3`, `.m4a`).
- **Download:** `URLSession.bytes(for:)` with the token in the `X-Plex-Token` header (never in
  a logged URL), streamed into `Tracks/tmp/`. It checks the size against `Part.size`, then
  moves the file into the cache. Identical requests that run at the same time share one download.
- **Index:** a small JSON file (`index.json`, decided) of key → size and last-access date. Every play
  updates last-access. On launch, rebuild the index from the files on disk if needed.
- **Eviction:** LRU, run after each insert, until the total is under the size limit (default
  2 GB, set in Settings, with a "Clear cache" button). The playing track and the prefetched
  next track are never evicted. Partial temp files are deleted on launch.
- **Prefetch:** when a track starts, download the next track in the queue. This is the
  `Player`'s existing look-ahead: it resolves the next track through the cache, and cancels
  that resolve on skip. If you skip ahead, the old prefetch is cancelled.
- **Startup delay:** a track from the cache starts immediately. An uncached Plex track with a
  known size starts after a short preroll (about two seconds of audio) while it keeps
  downloading (#0039): the player reads it through `ProgressiveDownload`, decodes on its own
  thread with CoreAudio and feeds PCM buffers to the same player node (EQ, analyzer and
  gapless scheduling are unchanged). A far read (an `moov` atom at the end) is one HTTP
  range request; a container that cannot be read while arriving, or a track without a size,
  falls back to waiting for the whole file. The player pauses and shows `isBuffering` if
  playback catches up with the download, and seeks beyond the downloaded bytes land at the
  edge (`bufferedTime`).
- **Tests:** eviction order, pinning, size accounting and index rebuild, using temp
  directories and a stub downloader.

### Plex (PlexKit) (removed by #0074)
Follows `docs/plex-music-library.md`:
- `PlexAddress.normalize(_:)`: add `http://` and `:32400` when missing; `https` passes through.
- `PlexClient`: async `URLSession`, `Accept: application/json`, `X-Plex-Token` header,
  `X-Plex-Client-Identifier` (a UUID stored once). Paging uses
  `X-Plex-Container-Start` and `X-Plex-Container-Size`.
- Endpoints: `/identity`, `/library/sections` (filter `type == "artist"`), artists `type=8`,
  albums `type=9` or `/children`, tracks `type=10` or `/children`, search `title=`.
  Never hard-code section 5.
- `ConnectionTest`: identity → sections with token → a music section exists. Each failure
  maps to the message in the doc. Save the `machineIdentifier`; if it changes, clear the
  selected library.
- Auth: paste-a-token first (unblocks development), then PIN sign-in through plex.tv
  (#0014; the by-hand results are in `docs/plex-music-library.md`). Store the token in the Keychain.
- Artist names: group display names by a normalized key (`&` vs `and`, trailing `;`, case).
- Album art: `/photo/:/transcode` thumbnail URL, with a placeholder when there is no `thumb`.

### App and skins
- **Skinned windows:** host the SwiftUI sprite views in a borderless `NSWindow`
  (`NSHostingView`), dragged by the title bar and shaped by `region.txt`. Draw at
  integer scale with nearest-neighbor sampling. Existing `SpriteImage` and
  `SpriteButtonStyle` (`App/MainWindowView.swift`) are reused.
- **What the skins show for Plex:**
  - The main window's marquee shows "Artist - Title" in the `text.bmp` font.
  - Time uses `numbers` or `nums_ex`.
  - kbps and kHz come from Plex `Media.bitrate` and `audioSampleRate`. Mono/stereo comes
    from `audioChannels`.
  - Position, volume, balance, shuffle and repeat are drawn with skin sprites.
  - The visualizer uses `viscolor.txt`.
  - The playlist window shows the queue in `pledit.txt` colors.
  - The EQ window drives `AVAudioUnitEQ`.
- **Plex browser:** a normal SwiftUI window (unskinned, as the brief allows). It has
  sidebar, artists, albums and tracks, plus search. Double-click plays. "Add to playlist"
  adds to the queue.
- **Settings** (SwiftUI `Settings` scene): Library, Music Assistant, Skins (the Plex and Cache
  sections were removed by #0074).
- **Info.plist:** `NSAppTransportSecurity.NSAllowsLocalNetworking = YES` plus a `ts.net` exception domain
  (subdomains, insecure HTTP loads; #0172),
  `NSLocalNetworkUsageDescription`, set through `project.yml`.

## Milestones

**M1: Playback core**
1. PlayerKit package and AudioCore: `Track`, queue, the AVAudioEngine graph, transport, seek,
   volume and balance.
2. Gapless scheduling of the next track.
3. 10-band `AVAudioUnitEQ` with preamp and presets.
4. Analyzer tap and FFT.
5. Local files: open or drop audio files into the queue.
6. Now Playing info and media keys.

**M2: Plex connection** (removed by #0074)
1. PlexKit client, JSON models and paging, tested with a `URLProtocol` stub.
2. Address normalization and the connection test with its error messages.
3. Keychain token store; Settings › Plex with a paste-token field and a library picker.
4. Info.plist ATS and Local Network keys; check that `joe`, `.local` and an IP all connect.
5. TrackCache: download, index, LRU eviction with pinning, prefetch of the next track,
   Settings › Cache.
6. PIN sign-in through plex.tv, and `plex.direct` HTTPS URIs from `/resources`.

**M3: Plex browser** (Plex items removed by #0074)
1. SwiftUI browser of artists, albums and tracks, with search and paging.
2. Artist-name de-duplication, and album art with a placeholder.
3. Play and enqueue from the browser; map Plex tracks to `Track`.

**M4: Main window complete**
1. Webamp fallback rules: numbers/nums_ex, balance → volume, default viscolors.
2. `text.bmp` bitmap font and the scrolling marquee.
3. Time digits, kbps/kHz, mono/stereo, and the play indicator wired to the player.
4. Position, volume and balance sliders, plus shuffle and repeat.
5. Visualizer (spectrum and oscilloscope) in `viscolor.txt` colors.
6. Borderless `NSWindow` host with title-bar drag, close, minimize and `region.txt` shape.
7. `skintool --png` offscreen render for comparison with Webamp.

**M5: EQ and playlist windows**
1. Skinned EQ window wired to `AVAudioUnitEQ`, including presets.
2. Skinned playlist window (queue, `pledit.txt` colors, resize, reorder, remove).
3. Docking and snapping; window positions, queue and EQ settings persist.
4. Shade modes.

**M6: Skin library**
1. Background index of the skins folder in SQLite (hash, name, readme, status).
2. Thumbnails from the offscreen renderer.
3. `LazyVGrid` browser with search, filters, random skin and apply. Interim: a Skins menu
   with next and previous.

**M7: Polish**
- Cursors (`.cur`), performance across the full corpus, corpus run of 1,000 skins.

**M14: Roadie release** ([#0151](../issues/0151.md))
- Rename the app to Roadie, sign and notarize it, ship a DMG from https://roadie.sstools.co/ with
  Sparkle updates. Work items W1 to W14 are in [design/release.md](design/release.md).

**M15: Music selection** ([#0173](../issues/0173.md))
- Pick music the way Winamp did, without a file dialog. The spec is
  [music-selection-features.md](music-selection-features.md).
  1. Jump to File: bare `J` or ⌘J opens a search over the playlist's rows; Return plays.
  2. A play-next queue with `[n]` markers (`Q`, the playlist's right-click menu, Jump to File's Queue button),
     plus Play Next in the Library, on This Mac and on Music Assistant.
  3. Library ↔ playlist editor: drag Library rows and Finder files in at the drop row, a Media Library item in the
     skinned menu, and the Library opens on its search field.
- Children #0174 to #0185. #0174 checks the Winamp 5.x behaviours the spec leaves open; the user does it.

**M16: Test automation** ([#0192](../issues/0192.md))
- The tests that would have caught 0.0.4's bugs (#0186–#0191), and the workflow that keeps adding them. Design in
  [design/test-automation.md](design/test-automation.md): a hosted `RoadieTests` bundle and a test-mode
  `RoadieConfiguration` for the app; recorded Music Assistant fixtures with their quirks pinned and a scripted,
  stateful server; tiny committed audio fixtures; an XCUITest target run in the VM over a cached, manifest-driven
  selection of Museum skins; a `--ui` tier per UI-touching issue and per milestone; coverage floors; and the rules
  (fast tests before review, regression test first, a UI test per feature) in `issues/Issues.md`.
- Children #0193 to #0213.

## Verification
- `swift test` for SkinKit and PlayerKit: the folder index, queue save and restore, Music Assistant decoding against
  recorded fixtures, and the connection-test error paths.
- Opt-in integration tests: `MA_URL` + `MA_TOKEN` (`MusicAssistantIntegrationTests`). Skipped when the variables are
  unset. The token is never written to disk.
- Manual check in the app:
  1. Connect to `joe` in Settings.
  2. Browse to an album and play it.
  3. Seek, and confirm EQ sliders change the sound and the visualizer moves.
  4. The next track starts with no gap (it was prefetched). Lower the cache limit and
     confirm the oldest files are evicted.
  5. Switch skins during playback with no glitch.
- `skintool Skins/` reports all 10 sample skins as ok after the M4 fallbacks.

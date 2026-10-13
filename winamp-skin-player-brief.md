# Classic Winamp Skin Player for macOS: Project Brief

Working title: TBD (pick a name later; do not use "Winamp" or "Nullsoft" in the app name or bundle ID).

## Goal

A native macOS music player that faithfully renders **classic Winamp 2.x skins (`.wsz`)**, plus a library browser for a large local collection of skins bulk-downloaded from the Internet Archive.

## Non-goals (v1)

- Modern Winamp 3/5 skins (`.wal`, XML-based). Detect and report as unsupported.
- Streaming services, Milkdrop/AVS visualizations, plugins.
- Redistributing any third-party skins or Winamp assets.

## Platform and stack

- macOS 14+, Apple Silicon first.
- Swift, Swift Package Manager or XcodeGen (no hand-maintained .xcodeproj if avoidable).
- **AppKit** for the skinned windows (borderless `NSWindow`s, custom `NSView` drawing at integer scale, nearest-neighbor sampling). SwiftUI is fine for non-skinned UI (settings, skin library browser).
- **AVAudioEngine** for playback: `AVAudioPlayerNode` -> `AVAudioUnitEQ` (10 bands) -> mixer -> output.
- ZIP: use a maintained Swift package (e.g. ZIPFoundation). BMP decoding via ImageIO/`NSBitmapImageRep`; add a fallback decoder if real-world skins fail.

## References (study, do not copy blindly)

| Project | Use it for | License note |
|---|---|---|
| [captbaritone/webamp](https://github.com/captbaritone/webamp) | **Source of truth** for sprite coordinates, file names, `region.txt`, `viscolor.txt`, `pledit.txt` parsing, fallback behavior. Port the sprite tables from its skin sprites definitions rather than inventing coordinates. | MIT. Porting is fine; keep attribution in a NOTICE file. |
| [wishval/wamp](https://github.com/wishval/wamp) | Architecture of a native Swift/AppKit Winamp 2.x clone: `SkinManager` / `SkinModel` / `SkinParser`, AVAudioEngine graph, playlist and state persistence. | License unverified. **Check before copying any code.** Read for structure only until confirmed. |
| [pzzzy/macwamp](https://github.com/pzzzy/macwamp) | Pixel-grid drawing at 2x integer scale, window layout, hit-testing in AppKit. | Check license before copying. |
| [wsz Rust crate](https://docs.rs/wsz) | Compact data model for a parsed skin; screenshot rendering approach. | Check license. |
| Audacious "Winamp Classic Interface" plugin | Mature native behavior reference (shade mode, docking, playlist). | Copyleft. **Do not copy code.** Behavior reference only. |
| winampskins.neocities.org | Human-readable skin format guide. | Docs. |

## Skin format essentials

- A `.wsz` is a ZIP. Files may be at the root **or inside a single subfolder**. File name matching must be **case-insensitive**.
- Mostly BMPs: `main`, `titlebar`, `cbuttons`, `shufrep`, `posbar`, `volume`, `balance`, `playpaus`, `monoster`, `numbers` / `nums_ex`, `text`, `eqmain`, `eq_ex`, `pledit`, `gen`, `genex`, `mb`, plus text configs `viscolor.txt`, `pledit.txt`, `region.txt`, and optional `.cur` cursors. Verify the full list against Webamp.
- **Any file may be missing.** Fall back per file to a base skin. Since we can't ship the original base skin, generate a programmatic fallback (MacWamp does this) and allow the user to point at their own base skin.
- Text files are loosely formatted (comments, odd whitespace, Windows line endings, non-UTF-8 encodings). Parse defensively.
- `region.txt` defines non-rectangular window shapes; apply via window shape / hit-test mask.
- Windows: main 275x116, equalizer 275x116, playlist resizable (minimum 275x116, grows in fixed increments; confirm increments in Webamp). Each has a shade mode.
- Real-world corpus is messy: malformed ZIPs, 8-bit palette BMPs, wrong sizes, duplicates. The parser must never crash; return a typed error or a partial skin with warnings.

## Features

### v1: Player
1. Main window: transport, seek bar, volume, balance, shuffle/repeat, time display (bitmap digits), scrolling title text (bitmap font), mono/stereo indicator, play state.
2. Equalizer window: 10 bands at 60, 170, 310, 600, 1k, 3k, 6k, 12k, 14k, 16k Hz, preamp, on/auto toggles, wired to `AVAudioUnitEQ`.
3. Playlist window: add files/folders, drag and drop, reorder, remove, current-track highlight using `pledit.txt` colors, resizable.
4. Windows dock/snap together like the original; positions persist.
5. Skin switching: drag a `.wsz` onto any window, or choose from the library. Switch atomically without restarting playback.
6. Spectrum analyzer and oscilloscope in the main window using `viscolor.txt` (simple FFT tap on the engine is fine).
7. Formats: whatever AVFoundation plays (MP3, AAC, ALAC, WAV, AIFF). FLAC if AVFoundation supports it on the target OS; otherwise defer.

### v1: Skin library
1. Point at a folder of `.wsz` files (tens of thousands). Index in the background into a local SQLite store: file hash, name, readme text, parse status, warnings.
2. Generate a thumbnail per skin by rendering the main window offscreen. Cache to disk.
3. Grid browser (SwiftUI `LazyVGrid`) with search by name/readme text, filter by parse status, "random skin" button, apply on click.
4. De-duplicate by content hash.

### Tooling
- `scripts/download-skins.sh`: wraps the Internet Archive CLI:
  ```bash
  pip install internetarchive
  ia download --search 'collection:winampskins' --glob '*.wsz' --destdir "$DEST" --checksum
  ```
  Before writing the glob, inspect a sample of items (`ia list <identifier>`) to confirm extensions; include `.zip`-packaged classic skins if present. Script must be resumable.
- A CLI target (e.g. `skintool`) that parses a skin or a whole folder and prints a report (ok / partial with warnings / failed with reason). Used for corpus testing and headless thumbnail generation.

## Suggested architecture

```
Sources/
  SkinKit/          # pure parsing + model, no AppKit dependency where possible
    Archive/        # ZIP unpack, case-insensitive lookup, subfolder detection
    Parsers/        # viscolor, pledit, region, BMP loading
    Sprites/        # sprite coordinate tables ported from Webamp
    SkinModel.swift
  SkinRender/       # AppKit/CoreGraphics drawing of sprites into views, offscreen renderer
  AudioCore/        # AVAudioEngine graph, EQ, analyzer tap, playlist model
  App/              # windows, docking, menus, settings, library UI
  skintool/         # CLI
Tests/
  SkinKitTests/     # unit tests + corpus tests
```

Keep `SkinKit` free of UI so the CLI and tests can run headless.

## Milestones

1. **SkinKit + skintool**: parse a skin, print report, render main-window PNG offscreen. Run against a 1,000-skin sample; target zero crashes and record the failure rate.
2. **Main window**: playback of a single file with full skin rendering and working controls.
3. **EQ + playlist windows**, docking, shade modes, persistence.
4. **Skin library**: indexing, thumbnails, search, apply.
5. **Polish**: region shapes, cursors, analyzer, performance with the full corpus.

## Acceptance criteria

- The parser never crashes on any file in the full corpus; every skin gets a status.
- At least 95% of classic skins in a random 1,000 sample render with no missing sprites (fallbacks count as warnings, not failures). Report the actual number.
- Rendered main window for a handful of well-known skins visually matches Webamp's rendering of the same skin (compare screenshots side by side; document any differences).
- Skin switch during playback causes no audio glitch.
- Library indexes 100k skins without blocking the UI; search returns in under 200 ms.

## Ground rules

- Do not commit skins, Winamp bitmaps, or the demo MP3 to the repo. Test fixtures: generate synthetic skins in tests, and point corpus tests at a local path via env var (e.g. `SKIN_CORPUS_DIR`), skipped when unset.
- Add a NOTICE file crediting Webamp for ported sprite data.
- Verify APIs and package versions rather than guessing; if something in this brief turns out wrong (file names, sizes, increments), trust Webamp's source and update this doc.

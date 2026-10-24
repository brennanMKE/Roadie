# Changelog

All notable changes to Roadie are recorded here. The format is a strict subset of
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) that `scripts/render-changelog.py` reads:
`## [X.Y.Z] - YYYY-MM-DD`, `### Added|Changed|Fixed`, `- ` bullets, inline links and `code`.

## [Unreleased]

### Added

- LIST › Load in the playlist editor can load a Library playlist while This Mac plays its own queue, and Playback › Load Playlist from Library… does the same from the menu bar.

### Changed

- Jump to File on an empty playlist says how to add music.

### Fixed

- Double-clicking a track in the playlist editor, or choosing one in Jump to File, plays that track on a Music Assistant queue instead of restarting the first one.

## [0.0.4] - 2026-10-24

Winamp-style music selection: Jump to File, a play-next queue with [n] markers, and Play Next from the Library.

### Added

- Jump to File: press J in any skinned window (or ⌘J) and type a few letters to find a track in the playlist; Return plays it.
- In Jump to File, Queue (or ⇧Return) adds the selected track to the play-next queue without stopping the current song.
- A play-next queue: press Q in the playlist editor (or right-click › Queue) to play the selected tracks next. Queued tracks show [1], [2], … and play in order before the playlist continues.
- On a Music Assistant queue, Queue (Q) moves the selected tracks to play right after the current one.
- Media Library in the skinned windows' menu (⌘L); the Library opens with the cursor in its search field.
- Play Next in the Library: plays a track or album right after the current song without replacing the playlist (This Mac and Music Assistant).
- Drag tracks and albums from the Library into the playlist editor; on This Mac they go in at the drop row, on Music Assistant at the end.

### Changed

- Files dropped on the playlist editor go in at the row under the pointer, as in Winamp, instead of always at the end.

## [0.0.3] - 2026-10-23

### Fixed

- A Music Assistant server can be added by its Tailscale name (`http://<machine>.<tailnet>.ts.net:8095`), and an https address on port 8095 that can't be reached now explains that Music Assistant serves plain http there.

## [0.0.2] - 2026-10-23

A friendlier first launch: Roadie now helps you get skins and pick your music folder. Music Assistant is optional.

### Added

- A Welcome window on first launch: skins (with a one-click way to the Winamp Skin Museum), a music folder, and optional Music Assistant. Help › Welcome to Roadie… brings it back.
- `~/Roadie/Skins` is created and used as the skins folder when none is set.
- The No Skin Loaded placeholder has a Browse the Skin Museum… button.

## [0.0.1] - 2026-10-23

The first public build: a rough draft to get Roadie started. More is on the way.

### Added

- Classic Winamp 2.x `.wsz` skins with the main, equalizer and playlist windows, docking, shade modes and the visualizer.
- Browse and play your Music Assistant library, or local files and folders.
- This Mac as a Music Assistant player, and playback on any other Music Assistant player.
- Music Assistant playlists you can create, edit and play.
- A skin browser for your skins folder and the Winamp Skin Museum.
- Quick Look thumbnails and previews for `.wsz` files.
- Updates through Sparkle.

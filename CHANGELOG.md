# Changelog

All notable changes to Roadie are recorded here. The format is a strict subset of
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) that `scripts/render-changelog.py` reads:
`## [X.Y.Z] - YYYY-MM-DD`, `### Added|Changed|Fixed`, `- ` bullets, inline links and `code`.

## [Unreleased]

### Added

- Jump to File: press J in any skinned window (or ⌘J) and type a few letters to find a track in the playlist; Return plays it.
- In Jump to File, Queue (or ⇧Return) adds the selected track to the play-next queue without stopping the current song.
- A play-next queue: press Q in the playlist editor (or right-click › Queue) to play the selected tracks next. Queued tracks show [1], [2], … and play in order before the playlist continues.
- Media Library in the skinned windows' menu (⌘L); the Library opens with the cursor in its search field.

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

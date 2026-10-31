# Changelog

All notable changes to Roadie are recorded here. The format is a strict subset of
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) that `scripts/render-changelog.py` reads:
`## [X.Y.Z] - YYYY-MM-DD`, `### Added|Changed|Fixed`, `- ` bullets, inline links and `code`.

## [Unreleased]

### Added

- MilkDrop presets in the Visualization window: 42 presets from MilkDropMetalKit, and your own folder of .milk files in Settings › Visualization. The classic visualizations stay in the list.
- Play a Library playlist: double-click it, right-click › Play / Play Next / Add to Queue, or drag it onto the playlist editor.
- Drag an artist from the Library onto the playlist editor; right-click an artist for Play, Play Next and Add to Queue.
- LIST › Load in the playlist editor can load a Library playlist while This Mac plays its own queue, and Playback › Load Playlist from Library… does the same from the menu bar.
- Help › Playlists and the Queue… explains how the playlist editor, the Library's playlists and saving a queue fit together.
- A Visualization window (⇧⌘K, or the clutter bar's V menu) with five classic visualizations in the skin's colours.
- Settings › Visualization (⌥⌘K): how often presets change, blend time, order, your own presets folder, overlay timing and opening the visualization when playback starts.
- The Visualization window goes full screen with ⌥Return or a double-click; Escape comes back.
- In the Visualization window, ← → (or Space and Delete) change presets, H cuts straight to the next, R switches random and in-order, ` locks the preset, and presets change on their own every 16 seconds or so, as in MilkDrop.
- L in the Visualization window lists the presets; type to search, Return to switch.
- The Visualization window shows the song, artist, time and what's next over the picture; it and the pointer hide after 3 seconds without mouse movement.
- MilkDrop's song title on track change (T shows it), F2–F5 corner readouts, and F1 for the keyboard shortcuts in the Visualization window.
- The Visualization window respects Reduce Motion and Dim Flashing Lights, keeps its overlay up for VoiceOver, and warns about flashing the first time it opens.

### Changed

- Jump to File on an empty playlist says how to add music.

### Fixed

- A Music Assistant connection made right at launch could drop again a moment later.
- Right after launch, a play or drop on a Music Assistant speaker no longer fails with "Can't reach the Music Assistant server".
- Dragging albums and tracks from the Library onto the playlist editor adds them.
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

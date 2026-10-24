# Roadie: Winamp-style music selection

Handoff spec for Claude Code. Goal: make picking music in Roadie feel like classic Winamp, where you rarely touched a file dialog. Follow the repo's issue workflow in `issues/Issues.md` and the model rules in `AGENTS.md`: file each phase below as its own issue (next free numbers after 0169), plan, implement, review, and never mark anything resolved without my explicit confirmation.

## 1. How Winamp did it

Winamp had three ways to choose music. Each served a different moment.

### 1.1 Playlist editor (Winamp 2.x)

The playlist window *was* the queue. Music got into it by:

- **ADD button menu** (bottom left): Add URL, Add Dir, Add File. Roadie already has these (`PlaylistWindowView.run(_:)`: `PLAYLIST_ADD_FILE`, `PLAYLIST_ADD_DIR`, `PLAYLIST_ADD_URL`).
- **Drag and drop** from Explorer onto the playlist, at the drop position. Roadie accepts URL drops (`PlaylistView.dropDestination(for: URL.self)`) but always appends.
- **Shell verbs**: "Enqueue in Winamp" on any audio file (`winamp.exe /ADD <file>`).

The common power-user habit: load the *entire* collection into one big playlist once, then never browse it. Use Jump to File instead.

### 1.2 Jump to File (the `J` key)

The feature people remember most. Press `J` with any Winamp window focused:

- A small plain dialog opens (not skinned) with a text field and a list of playlist entries.
- Typing filters the list live. Multiple words narrow it (all must match). Matching was against the displayed title ("Artist - Title") and file name.
- `Enter` or double-click **jumps**: plays that entry immediately.
- A **Queue** button (later 2.x and 5.x, via the bundled `gen_jumpex` plugin) adds the entry to a play-next queue without interrupting the current song.
- Queued entries show their queue position, `[1]`, `[2]`, etc., in the playlist and are highlighted. When the current song ends, the queue plays in order, then normal playlist order resumes.
- Reopening `J` keeps the previous search text, selected, so you can retype or reuse it.
- Command line equivalent: `/JUMPTO`.

Sources: Hydrogenaudio threads describing `J` (play or enqueue as next, `[n]` markers); Winamp's `cmdline.txt` (`/JUMPTO`, `/ADD`, JTFE `/ADD \\QUEUE` which both appends and queues).

### 1.3 Media Library (Winamp 5)

A separate docked window. Left tree (Local Media, Playlists, etc.), a search box, filter panes on top (artist / album, later 3-pane with genre), a track list below. Double-click plays (replacing), "Enqueue" appends, drag rows into the playlist editor to insert. Toggled from the main window. Roadie's Library window (`LibraryWindowView`, folder index via `FolderBackendKit`) already covers most of this, but it is a native SwiftUI window and is disconnected from the playlist window.

### 1.4 What to verify before building (do not guess)

These details vary by Winamp version and I have not confirmed them. Check against a real Winamp 5.x build (it still installs from winamp.com or archive.org, runs under a Windows VM or CrossOver) before treating them as requirements:

- Where the `[n]` marker sits in the playlist row (end of the title vs. before the time column).
- What playback does after the queue empties: continue after the last *queued* track, or return to where it was before the queue started. Winamp 5 / JTFE had an option for this.
- Whether a bare `Q` key in the playlist editor toggled queue for the selection in stock Winamp 5, or only with JTFE.
- Winamp 5's Media Library toggle shortcut (believed to be `Alt+L`).

Webamp (webamp.org) is useful for the 2.x playlist editor and ADD menu, but it has no Jump to File and no Media Library, so it cannot settle these.

## 2. What Roadie has today (relevant parts)

| Area | Where | Notes |
|---|---|---|
| Bare Winamp hotkeys | `SkinKit/Layout/WinampHotkeys.swift`, `App/Window/SkinWindow.swift` `keyDown` | Z X C V B, arrows, S R L. No `J`. |
| Local queue | `AudioCore/PlayQueue.swift` | `tracks`, `currentIndex`, shuffle bookkeeping, `next()`, `advanceAfterTrackEnd()`, `indexAfterCurrentEnds()`. No play-next queue. |
| Gapless | `AudioCore/Player.swift` (~l.503), `GaplessScheduler.swift` | Schedules the next track from `queue.indexAfterCurrentEnds()`. Any queue change must flow through this. |
| Queue persistence | `LocalPlayback/QueueSnapshot.swift`, `QueueAutosaver.swift` | Saves items, current index, repeat, shuffle. |
| Playlist rows | `App/Playlist/PlaylistModel.swift` (`playRow(_:)`, `playFirstSelected()`), `PlaylistWindowOverlays.swift` (key handling), `SkinKit/Display/PlaylistText.swift` (row text) | Rows come from `QueueRowsSource`: `.local`, `.remote(output)`, `.none`. |
| Remote queues | `LibraryBrowser/QueueRows.swift`, `QueueEditPlan`, `MusicAssistantBackend+Queue.swift` | Music Assistant queues are editable. `MAQueueOption` already has `.next`. |
| Library | `App/Browser/*`, `LibraryBrowser/*`, `FolderBackendKit/FolderIndex.swift` | Artists / Albums / Playlists / Search. Context menu: Play, Add to Queue, Add to Playlist. |
| Play modes | `MusicBackendKit/Playback.swift` `PlayMode` | `.replace(startIndex:)`, `.append`. No play-next. |
| Main menu | `SkinKit/Menus/MainMenu.swift` | Play File, Add to Playlist, window toggles. No Jump, no Library item. |

## 3. Features to build

Three phases, in order. Each is shippable alone.

### Phase A: Jump to File

The single biggest win. No new skin assets needed: Winamp's own dialog was a plain OS dialog, so a native window is authentic.

**Trigger**

- Bare `J` while any skinned window is key: add `case jumpToFile` to `WinampHotkey`, map `"j"` in `WinampHotkeys.hotkey(...)` (same no-modifier, no-repeat rules as the other letters), handle it where `onHotkey` is wired.
- Main menu item "Jump to File…" (Playback group) so it is discoverable. Pick a ⌘ shortcut that does not collide with the existing ones (⌘J is free in `MainMenu.swift` today; confirm).
- Update the existing hotkey tests in SkinKit.

**Window**

- A small native panel (`NSPanel`, utility style, ~420x360, resizable, remembers its frame). Title "Jump to File". Becomes key so typing works immediately; field focused on open.
- One instance. `J` while it is open brings it front (Winamp toggled; front-or-open is friendlier on macOS, note the choice in the issue).
- `Esc` closes. Losing key status does not close it.
- Contents: search field, list (row number, "Artist - Title", time, matching the playlist editor's text via `PlaylistText.displayName` and `PlaylistText.time`), and buttons **Play**, **Queue**, **Close**.
- Reopen shows the last search text, fully selected.

**What it searches**

- The rows the playlist editor shows right now, from the same `QueueRowsSource` choice: local `PlayQueue.tracks`, or the remote queue snapshot for a Music Assistant output. `.none` shows an empty state ("This speaker's queue can't be listed").
- The list updates if the queue changes while the panel is open.

**Matching** (pure, testable, put it in a package, e.g. `LibraryBrowser/JumpToFileMatcher.swift`)

- Fold case and diacritics (`String.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)`), precomputed once per row, not per keystroke.
- Split the query on whitespace; a row matches when every token is a substring of its haystack (artist, title, album, file name).
- Keep playlist order in results (Winamp did not rank).
- Empty query shows all rows.
- Must stay responsive at 50,000 rows. Add a performance test; if a synchronous filter misses one frame budget, filter off the main actor with cancellation per keystroke.

**Keys in the panel**

- Typing goes to the field. `↑` / `↓` / Page Up / Page Down move the list selection without leaving the field.
- `Return`: Play the selected result (first result if none selected).
- `⇧Return` (and the Queue button): toggle queue for the selected result(s). Works only once Phase B exists; until then the button is hidden.
- Double-click a result: Play.
- Multi-select in the list allowed for Queue; Play uses the first.

**Play behavior**

- Reuse `PlaylistModel.playRow(_:)` with the row's index in the full queue, so local and remote follow the existing paths. Do not add a parallel play path.
- After Play, scroll the playlist editor so the row is visible and select it (Winamp's jump also moved the playlist view).
- "Close after Play" defaults on (setting can wait; hardcode on and note it).

**Acceptance**

- `J` from main, EQ or playlist window opens the panel with the cursor in the field.
- Typing `daft tech` finds "Daft Punk - Technologic" in a 10k-row queue with no visible lag.
- `Return` plays it and closes the panel; the playlist editor shows it selected.
- Works with a Music Assistant output (remote rows) and with This Mac.
- Unit tests for the matcher (tokens, diacritics, empty query, order) and the hotkey mapping.

### Phase B: Play-next queue with `[n]` markers

Winamp's queue is separate from playlist order: an ordered list of entries to play next, which empties as it plays.

**Model (local)**

- Add to `PlayQueue`: `public private(set) var upNext: [Track.ID]` (entry IDs, not indices, so reorders and removals do not break it; `Track.id` is already per entry).
- API: `toggleQueued(_ ids:)`, `enqueueNext(_ ids:)`, `dequeue(_ ids:)`, `clearUpNext()`, `queuePosition(of id:) -> Int?` (1-based).
- `remove(at:)`, `removeAll()`, `crop` drop removed IDs from `upNext`.
- `advanceAfterTrackEnd()` and `next()`: if `upNext` has an entry still in `tracks`, pop it and make it current. Otherwise current behavior.
- `repeatMode == .one`: track end still repeats the current track; `Next` still honors `upNext`. Write this down in a test.
- Shuffle: playing a queued entry must not disturb `shuffleOrder` / `nextPass` beyond what's needed to keep them a permutation. After the queue empties, resume per the decision in 1.4. **Default until verified: continue from the entry after the last queued track (unshuffled) or the next shuffle position from where the queue began (shuffled).** Record whichever rule is chosen in the issue and in tests.
- `previous()` ignores `upNext`.
- `indexAfterCurrentEnds()` must return the queued entry when there is one, so `GaplessScheduler` preloads the right file. This is the easy-to-miss part; add a `Player` test that queues a track and checks the scheduled next ID.
- Persistence: add `upNext` (as indices into `items` at save time) to `QueueSnapshot`, bump `currentVersion`, and load older versions with an empty `upNext`.

**Model (remote / Music Assistant)**

- No `[n]` markers; Music Assistant has no separate play-next list.
- "Queue" on remote rows moves them to play right after the current item, in the order chosen, using the existing remote reorder path (`QueueEditPlan` / backend queue editing). Successive Queue actions in one session go after the previously queued ones (track the count locally; reset when the current item changes).
- Library "Play Next" on Music Assistant uses `MAQueueOption.next`.

**UI**

- Playlist editor rows: render ` [n]` per 1.4 (placement to verify) for queued entries, in the skin's normal text color. Add a `PlaylistText` helper for the suffix and test it, including truncation with long titles.
- Playlist editor key `Q` (bare, playlist window key): toggle queue for the selected rows. Add to `PlaylistWindowOverlays.keyDown`. Note that `Q` is not a Winamp global hotkey, so it belongs in the playlist view, not `WinampHotkeys`.
- Playlist right-click menu (`PlaylistContextMenus`): "Queue" / "Dequeue" (title follows selection), "Clear Queue" when non-empty.
- Jump to File: Queue button and `⇧Return` go live; queued results show `[n]` too.
- Library context menus (`libraryTrackActions`, `libraryAlbumMenu`): add **Play Next** between Play and Add to Queue.
  - Add `PlayMode.next` ("append, then put these at the front of up-next in order"), mirroring JTFE's `/ADD \\QUEUE`.
  - `PlayRequest.next(_:in:)` and `.next(album:)` constructors with tests, matching the existing `.append` ones.
  - Local backend: append tracks, then `enqueueNext` their new entry IDs. Starts playback only if idle, like `.append`.
  - Music Assistant backend: `MAQueueOption.next`.

**Acceptance**

- Queue 3 rows with `Q`; they show `[1] [2] [3]`; when the current song ends they play in that order, markers count down, then normal order resumes per the chosen rule.
- Gapless transition into a queued track has no gap (same as normal advance).
- Removing a queued row renumbers the others.
- Quit and relaunch keeps the queue and its markers.
- Library "Play Next" on an album during playback plays that album after the current song, without replacing the queue.
- All new `PlayQueue` logic is unit tested in AudioCore, including shuffle and repeat-one cases.

### Phase C: Connect the Library to the playlist editor

Smaller items that remove friction between the two windows.

- **Drag from Library to playlist editor.** `PlaylistView` accepts `MediaIDTransfer` drops in addition to URLs. Insert at the row under the drop point (Winamp behavior), falling back to append below the last row. Local: expand via the backend, then insert at index (add `PlayQueue.insert(_:at:)` that keeps shuffle bookkeeping consistent, with tests). Remote: append, then move into place via the reorder path if the backend supports it; otherwise append only.
- **Drag from Finder inserts at the drop row** too, instead of always appending.
- **Open the Library from skinned windows.** Main menu item "Media Library" (window toggle, like Equalizer / Playlist Editor). Bare-key binding to be decided after 1.4 is verified; do not invent one.
- **Library search goes straight to results.** When the Library opens via the menu item, focus its search field.
- **Out of scope:** a skinned Media Library window. Classic 2.x skins have no Media Library assets; Winamp 5 drew one from the playlist editor bitmaps with a separate "gen" skin. Not worth it now. Revisit only after A and B ship.

## 4. Order of work and testing

1. Phase A (no model changes, immediate value).
2. Phase B model and tests in AudioCore, then playlist UI, then Library "Play Next", then Music Assistant mapping.
3. Phase C.

Run `scripts/verify.sh` through the Haiku runner per `AGENTS.md`. The App target has no unit tests, so each issue's resolution notes should list what to check by hand (panel focus, `J` from each window, `[n]` rendering on a few skins with odd playlist fonts, gapless into a queued track).

## 5. References

- Hydrogenaudio, "Jump to file, view playback queue, ID3 tag priority": https://hydrogenaudio.org/index.php/topic,62175.0.html
- VideoHelp forum, user staying on Winamp 2.77 for the J feature: https://forum.videohelp.com/threads/229868-Winamp-question
- Winamp source mirror, command line reference (`/JUMPTO`, `/ADD`, JTFE `/ADD \\QUEUE`): https://git.txlyre.website/txlyre/winamp/raw/main/Src/Winamp/resource/cmdline.txt
- OpenFi playlist editor walkthrough with Winamp 2 screenshots: https://openfi.sourceforge.net/howto_playlist2.php.html
- Winamp 5.5 changelog (Media Library 3-pane views, Smart Views): https://www.hwsetup.it/mobile/files/changelog/?objid=3986
- Wikipedia, Winamp (Media Library overview): https://en.wikipedia.org/wiki/Winamp
- Webamp (Winamp 2.9 playlist editor reference): https://webamp.org/

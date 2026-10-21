# Playlists, favorites and automatic playlists (Music Assistant)

Design for [#0132](../../issues/0132.md): managing playlists in the Library window and the Winamp playlist editor (PL window), favorites, Music Assistant's automatic playlists and recommendation rows, and saving the queue as a playlist. Written 2026-10-21 against the recorded server (Music Assistant 2.10.6, schema 65, `docs/ma-protocol/commands.json`, 310 commands) and the current `dev` branch of `music-assistant/server`, `music-assistant/models` and `music-assistant/frontend`. The orchestrator turns section 4 into a milestone of issues.

Scope boundaries: #0125 (per-speaker volume, Output panel) and #0123 (output selection races) are in flight and are not touched here: nothing below changes `OutputSelection`, `applyOutputSelection`, `OutputPickerView` or volume. #0076 (event shapes) stays open; this design records what events it needs and feeds it a capture recipe.

Non-goals: Music Assistant's smart playlists (`smart_playlist` plugin), playlist sharing/`set_access`, playlist migration between providers, audiobooks and podcasts, dislikes as a first-class state, genre browsing.

---

## 1. What Music Assistant supports

Sources, read-only on the web: `music_assistant/controllers/music/media/playlists.py` (`PlaylistController`), `controllers/music/media/base.py` (`MediaControllerBase`), `controllers/music/controller.py` (favorites, library, recently played), `controllers/music/recommendations/controller.py`, `providers/recommendations/__init__.py` (the library rows), `providers/builtin/__init__.py` and `constants.py` (built-in playlists, M3U-backed user playlists), `controllers/player_queues/controller.py` (`save_as_playlist`, `move_item`, `delete_item`, `clear`), `music_assistant_models/media_items/media_item.py` (`Playlist`, `ItemMapping`, `RecommendationFolder`), `music_assistant_models/enums.py` (`EventType`, `ProviderFeature`). Frontend: `src/views/LibraryPlaylists.vue`, `PlaylistDetails.vue`, `src/layouts/default/ItemContextMenu.vue`, `AddToPlaylistDialog.vue`, `CreatePlaylistDialog.vue`, `src/helpers/playlist_access.ts`, `favorites.ts`, `src/components/HomeWidgetRows.vue`, `src/plugins/api/index.ts`.

### 1.1 Version caveat: the recorded server vs. `dev`

`commands.json` is the truth for the user's server. The `dev` branch has things 2.10.6 does not. Every item below says which side it is on.

| Feature | On the recorded server (`commands.json`) | On `dev` only |
|---|---|---|
| Create, update, remove playlist | yes | `set_access`, `migrate_playlist` |
| `playlist_tracks` | `item_id`, `provider_instance_id_or_domain`, `force_refresh`, `allow_dynamic_tracks`; streamed in 500-item chunks | adds `favorite`, `search`, `limit`, `offset`, `sort_field`, `sort_direction`, `random_seed` |
| Add / remove tracks | yes, both return `BackgroundTask` | same |
| **Reorder** (`music/playlists/move_playlist_track`) | **absent** | present (`from_position`, `to_position`, 1-based; `ProviderFeature.PLAYLIST_TRACKS_MOVE`) |
| Favorites add/remove, `players/add_currently_playing_to_favorites` | yes | `favorite_updated` event, dislikes (`favorite: false`) |
| Recommendations (`music/recommendations`, `/items`) | yes | provider filter on rows |
| Recently played / added, in progress | yes | same |
| Radio library, `builtin/add_radio`, `radio_tracks` | yes | same |
| `player_queues/save_as_playlist` | yes (`BackgroundTask`) | same |
| Import / export M3U8 | yes (`import_playlist` has `library_matching`, `match_providers`; `dev` adds `match_policy`) | |
| Events | API page lists `media_item_added/updated/deleted/played`, `queue_items_updated`, `tasks_updated`; none recorded (#0076) | adds `favorite_updated`, `playlog_updated`, `provider_event` |

Consequence: drag-to-reorder is a server capability SkinAmp must detect at runtime (section 3.6), never assume.

### 1.2 Playlist model

`Playlist` (`media_item.py`, matches the `Playlist` schema in `docs/ma-protocol/openapi.json`): `item_id`, `provider` (`"library"` for library items), `name`, `sort_name`, `uri` (`library://playlist/<id>`), `provider_mappings[]` (`item_id`, `provider_domain`, `provider_instance`, `available`, `in_library`), `metadata.images[]`, `favorite`, `owner: str` (a display name, not a user id), `is_editable: bool`, `is_dynamic: bool` ("provider-driven and endless: tracks are yielded on demand", e.g. Apple Music stations), `supported_mediatypes` (default `{track}`). `dev` adds `access` (owner id, sharing, collaborative).

Where `is_editable` comes from: the provider that owns the playlist. The builtin provider sets `is_editable=False, owner="Music Assistant"` on its eight built-in playlists (`get_playlist`) and `True` on user playlists it stores as `<storage>/playlists/<id>.m3u` (`create_playlist` → `_reserve_playlist_file`). Streaming providers set it from ownership (your own Spotify playlist: editable; someone else's or an editorial one: read-only). Library sync copies the flag into the library row. Three gates in the controller: `add_playlist_tracks`, `remove_playlist_tracks` and `move_playlist_track` all raise `InvalidDataError("... is not editable")` when it is false, and the frontend's `canEditPlaylistItems` (`playlist_access.ts`) returns false first on `is_editable`. Renaming and deleting are not gated by `is_editable` but by scope (`update` and `remove` need `library.manage`; `music/library/remove_item` needs `library.write`): the frontend's `canManagePlaylist` allows it for any playlist with no `access` record, which on 2.10.6 is every playlist.

So for SkinAmp's UI, per playlist: **tracks editable** = `is_editable && !is_dynamic`; **renamable/deletable** = the token's scope allows it, discovered by trying (an error frame `error_code` with "scope"/"permission" in `details` → disable and say so); **reorderable** = tracks editable and the server has `move_playlist_track`.

Built-in playlists (`providers/builtin/constants.py`): `all_favorite_tracks` "All favorited tracks", `random_artist`, `random_album`, `random_tracks` "500 Random tracks (from library)", `recently_played` "Recently played tracks", `recently_added_tracks`, `infinite_mix` and `infinite_mix_favorites` (these two are `DYNAMIC_BUILTIN_PLAYLISTS`, `is_dynamic=True`). They appear in `music/playlists/library_items` as ordinary library playlists with `provider_mappings[0].provider_domain == "builtin"` and ids such as `random_tracks` (the recorded `playlists-page.json` has two of them: library ids 4 and 1). Their tracks are regenerated on each `playlist_tracks` call (random tracks cached 120 s server-side). Each can be hidden server-side (`library_remove` flips a config value instead of deleting), so a "delete" on one of them from SkinAmp would hide it in MA's own UI too: SkinAmp never offers delete on a built-in playlist.

### 1.3 Commands, arguments, responses, fixtures

Argument names are exactly those in `commands.json`. "Fixture" names the file under `Packages/PlayerKit/Sources/MusicAssistantKitStub/Fixtures/`; "capture" means it must be recorded with the recipe in 1.5.

| Area | Command | Args | Response | Fixture |
|---|---|---|---|---|
| List | `music/playlists/library_items` | `limit`, `offset`, `order_by` (`sort_name`), `favorite?`, `search?`, `provider?`, `summary?` | bare `[Playlist]`, no total | `playlists-page.json` (3 items, 2 built-in) |
| Count | `music/playlists/count` | `favorite_only?` | bare int | `playlists-count.json` |
| Get one | `music/playlists/get` | `item_id`, `provider_instance_id_or_domain`, `allow_update_metadata?` | `Playlist` | capture (`playlist-get`) |
| Tracks | `music/playlists/playlist_tracks` | `item_id`, `provider_instance_id_or_domain`, `force_refresh?`, `allow_dynamic_tracks?` | streamed `[Track]` in chunks of ≤500 (`partial: true` frames, then `partial: false`); each track carries `position` (**1-based**: the recorded first track has `"position": 1`) | `playlist-tracks.json` (5 of 500 kept) |
| Create | `music/playlists/create_playlist` | `name`, `media_types?`, `provider_instance_or_domain?` (note: `_or_domain`, not `_id_or_domain`) | `Playlist` (`provider: "library"`, `is_editable: true`, `owner` = the token's display name) | capture (`playlist-create`) |
| Rename | `music/playlists/update` | `item_id`, `update: Playlist` (the full object with `name` changed), `overwrite?` | `Playlist` | capture (`playlist-update`); on `dev`, `name` only changes with `overwrite: true` (`update.name if overwrite else cur_item.name`); verify on 2.10.6 in the capture |
| Delete | `music/library/remove_item` | `media_type: "playlist"`, `library_item_id`, `recursive?` | `null` | capture (`playlist-delete`) |
| Delete (alt) | `music/playlists/remove` | `item_id`, `recursive?` | `null`; needs `library.manage` | not used |
| Add tracks | `music/playlists/add_playlist_tracks` | `db_playlist_id` (library id), `uris: [String]` | `BackgroundTask` (`id`, `name`, `status`); queued server-side: album URIs expand to tracks, playlist URIs to their items, duplicates skipped, artists **not** accepted | capture (`playlist-add-tracks`) |
| Remove tracks | `music/playlists/remove_playlist_tracks` | `db_playlist_id`, `positions_to_remove: [Int]` (**1-based**; the frontend sends each track's `position`; the builtin provider removes "by 1-based positions in reverse order") | `BackgroundTask` | capture (`playlist-remove-tracks`) |
| Reorder | `music/playlists/move_playlist_track` | `db_playlist_id`, `from_position`, `to_position` (1-based, "Playlist positions start at 1") | `null`, synchronous ("returns once the provider holds the new order") | **absent on 2.10.6**; capture only if the user upgrades |
| Export | `music/playlists/export_playlist` | `db_playlist_id` | M3U8 text | capture (`playlist-export`) |
| Import | `music/playlists/import_playlist` | `m3u_data`, `library_matching?`, `match_providers?` | `Playlist` (new builtin playlist) | capture optional |
| Save queue | `player_queues/save_as_playlist` | `queue_id`, `name` | `BackgroundTask`; raises `QueueEmpty` on an empty queue, `InvalidDataError` when no item is a playlist media type; server does `create_playlist(name)` on builtin then `add_playlist_tracks` | capture (needs a non-empty queue) |
| Favorite | `music/favorites/add_item` | `item`: a URI string or item | `null`; a non-library item is added to the library first; per user (the token's user) | capture (`favorite-add`) |
| Unfavorite | `music/favorites/remove_item` | `media_type`, `library_item_id` | `null` | capture (`favorite-remove`) |
| Favorite now playing | `players/add_currently_playing_to_favorites` | `player_id` | `null`; resolves the player's current media to a library item | capture (needs a playing player) |
| Favorites list | `music/{tracks,albums,artists,playlists,radios}/library_items` | `favorite: true` + paging | bare array | capture (`tracks-favorites-page`) |
| Rows | `music/recommendations` | none | `[RecommendationFolder]` with empty `items`: `item_id`, `provider`, `name`, `subtitle?`, `icon?` (mdi name), `type` (`default`/`timeline`), `enabled_by_default`, `supports_provider_filter`, `uri` | capture (`recommendations`) |
| Row items | `music/recommendations/items` | `provider`, `item_id`, `providers?` | mixed array of `Artist|Album|Track|Playlist|Radio|ItemMapping|...`, each with `media_type`; library rows are limited to 10 items | capture (`recommendations-items-<row>`), one per row shown |
| Recently played | `music/recently_played_items` | `limit?`, `media_types?`, `user_initiated_only?`, … | `[ItemMapping]` (slim: `item_id`, `provider`, `name`, `uri`, `media_type`, `image`) | capture |
| Recently added | `music/recently_added_tracks` | `limit?` | `[Track]` | capture |
| Radios | `music/radios/library_items`, `/count` | as playlists | `[Radio]` / int | capture |
| Radio tracks | `music/radios/radio_tracks` | `item_id`, `provider_instance_id_or_domain` | `[Track]` for dynamic stations; error for endless streams | capture optional |
| Add radio | `builtin/add_radio` | `url`, `name`, `image_url?` | `Radio` | capture optional |
| Queue items | `player_queues/items` | `queue_id`, `limit?`, `offset?` | `[QueueItem]` (`queue_item_id`, `index`, `name`, `duration`, `media_item: Track?`, `image`, `available`) | `player-queue-items.json` (**empty**: nothing was playing); capture with a loaded queue |
| Queue edits | `player_queues/delete_item` (`queue_id`, `item_id_or_index`), `move_item` (`queue_id`, `queue_item_id`, `pos_shift`), `move_item_end`, `clear` (`queue_id`, `skip_stop?`), `play_index` (`queue_id`, `index`) | | `null`; `move_item`/`delete_item` refuse items at or before the buffered index (`IndexError`, or a silent return for delete) | capture optional (writes) |

Rows the `recommendations` provider builds on `dev` (`LibraryRowID`): `in_progress`, `recently_played`, `recently_added_albums`, `latest_episodes` (enabled by default); `recently_added_tracks`, `random_artists`, `random_albums`, `recent_favorite_tracks`, `favorite_playlists`, `favorite_radio`, `recent_artists`, `recent_tracks`, `forgotten_tracks/albums/artists`, `most_played_tracks`, `never_played_tracks` (off by default). All have `provider: "recommendations"`, `uri: library://folder/<item_id>`, `supports_provider_filter: true`, 10 items, no caching except podcast episodes. Streaming providers (Spotify, Apple Music, …) add their own rows, interleaved one-per-provider per pass (`zip_longest`). Which rows the 2.10.6 server returns is unknown until captured; the UI treats ids as opaque and shows `name`/`subtitle`/`icon`.

"Dynamic": random rows and the random built-in playlists change on every fetch; the frontend fetches on open and refreshes on `media_item_played` (`is_playing == false`) with a 1.5 s debounce. Recently played changes after every play.

### 1.4 Events

Pushed after `auth`, no subscribe (notes §8). Shapes from `base.py` (`dev`; the recorded API page lists the same names):

- `media_item_added` / `media_item_updated` / `media_item_deleted`: `object_id` = the item's `uri` (`library://playlist/12`), `data` = the full library item. Emitted by `add_item_to_library` (create playlist, favorite of a non-library item), `update_item_in_library` (rename), `remove_item_from_library` (delete), and `_request_metadata_refresh` after a **successful** add/remove/move of playlist tracks (so the event follows the background task's provider call, not the enqueue). The frontend's playlist list reloads on added/deleted with `object_id` starting `library://playlist`, and marks "update available" on updated.
- `favorite_updated` (`dev`): `object_id` = uri, `data` = `{uri, media_type, item_id, favorite, user_id}`. On 2.10.6 expect `media_item_updated` with the item's `favorite` instead; decode both.
- `queue_items_updated` and `queue_updated`: `object_id` = `queue_id`, `data` = the `PlayerQueue` (a count, not the items): any reorder, add, delete triggers `queue_items_updated`.
- `tasks_updated`: the `BackgroundTask` list; useful for "Adding 3 tracks…" progress, optional.
- `media_item_played`: refresh hint for Discover rows.

The envelope's `object_id` is unverified (#0076, `events.json` is empty). Decoding stays lenient (`MAServerEvent` already keeps `data` raw); the design never depends on an event: every event is a hint that triggers a refetch, and an explicit refetch follows each own write.

### 1.5 Capture recipe (the user runs it on the host, never an agent)

`scripts/record-ma-fixtures.py` only sends read commands on its `ALLOWED` list (`record()`, `Session.call`). Two additions:

1. **Reads, default run.** Add to `ALLOWED` and to `record()`: `music/playlists/get` (first playlist), `music/playlists/library_items` with `{favorite: true}` (`playlists-favorites-page`), `music/tracks/library_items` with `{favorite: true, limit: 3}` (`tracks-favorites-page`), `music/recommendations` (`recommendations`), `music/recommendations/items` for every returned row (`recommendations-items-<item_id>`, 3 items kept per row, counts in `original_item_counts`), `music/recently_played_items` `{limit: 5}`, `music/recently_added_tracks` `{limit: 3}`, `music/radios/count`, `music/radios/library_items` `{limit: 3}`, `music/playlists/export_playlist` for the first editable playlist (`playlist-export`; the M3U paths are scrubbed like other paths), `player_queues/items` for the first queue whose `items > 0` (`player-queue-items-loaded`, 5 kept). Then `/usr/bin/python3 -I scripts/record-ma-fixtures.py` and `--check` as today; the secret gate covers the new files.
2. **Writes, opt-in run: `--record-playlist-writes`.** A separate allowlist `ALLOWED_WRITES`, used only with the flag, and a self-cleaning script: `create_playlist {name: "SkinAmp fixture <run-id>"}` → `add_playlist_tracks` with the first two library track URIs → `playlist_tracks` (shows `position`) → `remove_playlist_tracks {positions_to_remove: [1]}` → `playlist_tracks` again → `update` with the name changed and `overwrite: true` → `favorites/add_item` on the first track → `favorites/remove_item` (restores the state only if the track was not already a favorite: read `favorite` first and skip both when it was) → `music/library/remove_item {media_type: "playlist"}` for the fixture playlist → in a `finally`, delete the playlist even if a step failed. Optionally `player_queues/save_as_playlist` on a queue that already has items, deleted the same way. It also tries `music/playlists/move_playlist_track` once and records the error frame (`error-unknown-command-move`), which is the 2.10.6 answer. Pushed frames during the run are written to `events-playlists.json` (the first recording of `media_item_*` events: #0076 gets its envelope). Fixture names as in the table. Writes happen only on a throwaway playlist the script created; nothing else is modified.

Until the capture lands, implementation uses synthetic routes (`FixtureScript.Route.result(...)`) built from the openapi schemas; the capture replaces them and `ModelDecodingTests` gain one decode test per recorded file.

---

## 2. UX design

Principles: the skinned windows stay Winamp (the PL editor is the queue, its five menus keep their names); the Library window is a native Mac window where Winamp has no answer, with macOS Music conventions (sidebar groups, "Add to Playlist ▸" submenu, hearts, drag-and-drop, Delete key, confirmations only for destructive and non-undoable actions). Nothing offers an action the backend cannot do: capabilities hide, per-item flags disable with a reason in the help tag.

### 2.1 Library window sidebar

Today: a flat `List` of `LibrarySection` (Artists, Albums, Playlists). New shape, two groups:

```
┌ Library ─────────────┐
│ LIBRARY              │
│   🎤 Artists         │
│   ▣ Albums           │
│   ♪≡ Playlists       │
│   ♥ Favorites        │
│   ((•)) Radio        │   ← only when the backend has .radio and count > 0
│                      │
│ DISCOVER             │   ← only with .recommendations (Music Assistant)
│   ◷ Recently played  │
│   ▶| In progress     │
│   ⊕ Recently added   │
│   … (rows MA enables by default)
│   ▾ Show all rows    │   ← footer toggle; off by default
└──────────────────────┘
```

Discover rows come from `music/recommendations`; the sidebar lists the rows with `enabled_by_default` (plus the user's opt-ins), each a selectable item with the row's `icon` mapped to an SF Symbol through a small table (`mdi-motion-play` → `play.circle`, `mdi-album` → `square.stack`, `mdi-music-note-plus` → `plus.square`, `mdi-timer-sand` → `hourglass`, `mdi-trophy` → `trophy`, `mdi-sleep` → `moon.zzz`, `mdi-podcast` → `antenna.radiowaves.left.and.right`, default `sparkles`). Rows from streaming providers get the provider's name as a tooltip. Selecting a row shows its items in the content column (2.5). The folder-style alternative (one "Discover" entry whose content column lists rows) is the fallback if the row count gets unwieldy; the sidebar form matches "I see that UI has automatic playlists" best.

Folder backend: Artists, Albums only (unchanged). Favorites appears only with `.favorites`.

### 2.2 Playlists list (content column)

```
┌ Playlists ──────────────────────────── [+▾] ┐
│ MY PLAYLISTS                                 │
│   Road Trip                         24       │
│   Sunday Morning                    8        │
│ BUILT-IN                                     │
│   500 Random tracks (from library)   ∞       │
│   All favorited tracks                       │
│   Recently played tracks                     │
│ SPOTIFY · read-only          🔒              │
│   Discover Weekly                   30       │
│   Chill Hits                        50       │
│                                              │
│ 12 of 12                                     │
└──────────────────────────────────────────────┘
```

- Grouping (pure helper `PlaylistGrouping`): "My Playlists" = `isEditable && source == .user`; "Built-in" = `source == .builtIn` (provider_domain `builtin` and `owner == "Music Assistant"`, or an `is_editable == false` builtin mapping); one group per other provider (`provider_domain` display name from `providers.json`), suffixed "· read-only" when none of its playlists is editable. Within a group, `sort_name` order (the server's). Paging stays (`PagedList`); groups are computed over loaded items and sections may grow as pages land.
- The `[+]` toolbar button (and a `New Playlist…` context item on empty space, and File › New Playlist… ⌘N while the Library window is key) opens a name sheet. Default name "New Playlist", trimmed, non-empty. Created on `builtin`. Selects the new playlist.
- Row context menu: Play, Shuffle (plays with `shuffle: true`), Add to Queue, separator, Favorite/Unfavorite, separator, Rename… (editable or any non-built-in; disabled with help "Music Assistant doesn't allow renaming this playlist" after a scope error), Delete… (never on built-in). Double-click (or Return) plays the playlist, replacing the queue, like albums.
- Rename: inline edit on the row (Return commits, Escape cancels), also via the context item and the detail header's title (click-to-edit). Delete: confirmation alert "Delete "Road Trip"? This removes the playlist from Music Assistant for every app. Tracks stay in the library." Buttons Delete (destructive) / Cancel. Delete key on a selected playlist asks the same.
- Trailing count: `trackCount` when known (the list items carry none on 2.10.6; known once the detail loaded, cached per id); "∞" for `is_dynamic`.

### 2.3 Playlist detail (detail column)

```
┌──────────────────────────────────────────────────────────────────┐
│ Road Trip                                        [▶ Play] [⋯]    │
│ 24 tracks, 1:32:10 · Music Assistant · you                        │
├────┬──┬───────────────────────────────┬────────────────┬─────────┤
│ #  │♥ │ Title / Artist                │ Album          │   Time  │
│ 1  │♥ │ Born to Run — Bruce Springsteen│ Born to Run    │   4:30  │
│ 2  │  │ Radar Love — Golden Earring    │ Moontan        │   6:26  │
│ 3  │♥ │ …                              │                │         │
│ ⋮  (drag rows to reorder when the server allows it)               │
├──────────────────────────────────────────────────────────────────┤
│ Adding 3 tracks…                                 (transient bar)  │
└──────────────────────────────────────────────────────────────────┘
```

Read-only:

```
│ Discover Weekly                                   [▶ Play] [⋯]   │
│ 30 tracks, 2:01:44 · Spotify · 🔒 Read-only                        │
```

- Header: name (editable inline when renamable), summary line (`LibraryFormat.trackSummary`), source, owner ("you" when `owner` equals the signed-in display name from `auth/me`, else the owner's name), a lock badge "Read-only" when `!isEditable`, "Dynamic" when `is_dynamic` (tracks are a sample; MA's `DynamicItemSample`).
- Columns: position (`position`, 1-based), heart (hover-visible when off, always when on; click toggles, no confirmation), title with artist beneath (as `TrackRow` does today), album, duration. The existing `TrackRow` grows the heart and the album cell behind options so album/search lists are unchanged.
- Multi-select (`Set<MediaID>` stays the selection type; positions come from the rows), Return plays from the first selected, Delete/⌫ removes the selected rows from the playlist (editable only; one undo-less confirmation when 10+ rows: "Remove 12 tracks from "Road Trip"?").
- Context menu on tracks: Play, Add to Queue, separator, Add to Playlist ▸, Favorite/Unfavorite, separator, Remove from Playlist (editable only). Playing a row starts the playlist from that row (`play_media(playlist, start_item: track)`, as MA does), the same `PlayRequest.play(_:in:album:)` rule with the playlist id as the container.
- Reorder: drag rows (`onMove` on the `List`) only when `canReorder`; the handle appears on hover; the row moves at once, `move_playlist_track(from, to)` is sent, and the list refetches on completion. Without server support there is no drag and the context menu has no Move items; a footer caption says "Reordering needs a newer Music Assistant" the first time a user drags (one-shot help).
- Drag in: tracks and albums dragged from the Artists/Albums/Search columns onto a playlist row in the Playlists list, or into the open playlist's detail, add them (MA expands albums). The drag payload is `MediaID` encoded as a custom UTType (`com.brennanmke.skinamp.media-id`); `.dropDestination(for: MediaIDTransfer.self)` on playlist rows highlights editable playlists only.
- Busy and errors: structural edits (add, remove, move, rename) show a thin transient bar under the list ("Removing 2 tracks…", "Adding 12 tracks…"); the list is interactive but structural edits are disabled until the refetch lands (3.5). A failure restores the previous rows and posts the message in the bar with a Retry button; it also goes to the main window marquee notice like playback errors, since the user may be looking at the skinned window.
- Empty editable playlist: `ContentUnavailableView("No tracks", "Drag tracks here, or use Add to Playlist in the Library.")`.

### 2.4 "Add to Playlist ▸" and Favorites in every list

The existing context item "Add to Playlist" appends to the **queue**; it is renamed **"Add to Queue"** everywhere (Winamp's playlist is the queue, but a native menu next to real playlists must not say "playlist" for it). New items on tracks and albums (artists: see open decision 3), in album tracks, artist albums, search results, playlist tracks and Discover rows:

```
Play
Add to Queue
──────────────
Add to Playlist        ▸ ┌ Road Trip          ┐
Favorite                 │ Sunday Morning     │
                         │ ──────────────     │
                         │ New Playlist…      │
                         └────────────────────┘
```

- The submenu lists editable playlists (`PlaylistEditPolicy.addTargets`): most recently used first (last 3, UserDefaults), then the rest by name; built-in and read-only playlists are left out; the playlist currently open is left out. "New Playlist…" opens the name sheet and adds the selection to the new playlist. With no editable playlist the submenu shows only "New Playlist…".
- Feedback: the main window marquee notice "Added 3 tracks to Road Trip" (the existing `StatusNotice`); with the playlist open, its bar shows the progress.
- Favorite: the item's `favorite` flips at once; the heart in the row follows the model. Albums and artists have hearts in their rows too (hover). The Favorites section lists them.

### 2.5 Favorites and Discover (content column + detail)

Favorites: the content column lists kinds with counts; the detail shows the paged list of that kind (reusing `PagedListView`, `AlbumListView`, `TrackRow`):

```
┌ Favorites ───────────┐ ┌──────────────────────────────────────────┐
│ ♪ Tracks         142 │ │ Tracks                                   │
│ ▣ Albums          23 │ │ ♥ Title / Artist · Album · Time          │
│ 🎤 Artists         9 │ │ …                                        │
│ ♪≡ Playlists       3 │ │ 100 of 142                               │
│ ((•)) Radio        2 │ └──────────────────────────────────────────┘
└──────────────────────┘
```

Counts from `*/count {favorite_only: true}` (one call per kind on open, cheap). Unfavoriting a row removes it from the list after the refetch (the heart greys at once). Albums push their tracks like the artist column does.

Discover row (selected in the sidebar): a list of the row's items, mixed kinds, each row showing kind icon + art + name + a secondary line (artist for tracks/albums, "Playlist", "Radio"), with Play / Add to Queue / Add to Playlist / Favorite in the context menu; double-click plays. A Refresh button reloads (random rows change). Rows are "automatic playlists" in the user's words: a "Play All" button in the header plays the row's playable items as one queue (`play_media` with the item URIs). Items that are `ItemMapping` only (recently played) resolve lazily through `music/item_by_uri` when played or favorited; the list shows what the mapping has.

Built-in playlists ("500 Random tracks", "All favorited tracks", …) stay in Playlists › Built-in (they are playlists on the server) and are not duplicated in Discover.

### 2.6 The Winamp PL editor and Music Assistant's queue

The PL window is the queue of the selected output, which is Winamp's meaning of "playlist". Today (`PlaylistModel`): the local AudioCore queue when This Mac is selected, empty when a speaker is. New rule: the rows are a `QueueRows` source chosen by `PlayerModel`:

| Selected output | Feed | Rows | Current row |
|---|---|---|---|
| This Mac | local queue | AudioCore queue (unchanged) | `player.queue.currentIndex` |
| This Mac | Music Assistant over Sendspin (#0109) | MA queue of the wrapper player | `current_index` |
| Speaker or group | — | MA queue of the leader (`queue_id` = leader's player id, redirect as `play` does) | `current_index` |

The remote rows come from `player_queues/items` (paged 500 at a time, first page at once, the rest in the background up to a cap, decision 10) and refresh on `queue_items_updated` / `queue_updated` for that queue id (150 ms debounce, as `playbackActivity` does) and after each own edit. The window's running time, shade strip text and row numbers work the same from `QueueRows`.

The five menus with a remote queue:

| Menu | Entry | Local queue (today) | Music Assistant queue |
|---|---|---|---|
| ADD | File / Dir | open panels, local files | unchanged for This Mac; on a speaker the existing refusal notice (`LocalPlaybackGate`) |
| ADD | URL | nothing today | nothing (future: `builtin/add_track`/`add_radio`, decision 12) |
| REM | Remove selected / Crop / Remove all | `Player.removeTracks` / `clearQueue` | `player_queues/delete_item` per row (highest index first), crop = delete the unselected, remove all = `player_queues/clear` |
| SEL | all / none / invert | local | local (selection is SkinAmp's) |
| MISC | Sort / Randomize / Reverse | `Player.sortQueue` … | not available: the Sort menu entries are disabled and the marquee says "Not available for Music Assistant queues"; File Info shows the current MA item's details (title, artist, album, duration, format when `media_item` has it) |
| MISC | Generate HTML Playlist | from rows | from rows (works as is) |
| LIST | New | empty the local queue | `player_queues/clear` |
| LIST | Save | file panel (M3U8/M3U/PLS) | name sheet → `player_queues/save_as_playlist`; the notice "Saved queue as "Road Trip"" and the Library's Playlists list refreshes |
| LIST | Load | file panel, replaces and plays | picker sheet listing MA playlists (search field, grouped like 2.2) → `play_media(playlist, replace)` |
| rows | double-click / Return | `player.play(at:)` | `player_queues/play_index` |
| rows | drag up/down | `Player.moveTracks` | `player_queues/move_item(pos_shift)` per step for one selected row; multi-row drags on a remote queue are refused with a marquee notice (MA moves one item per call and would reorder visibly in steps) |
| keys | Delete | remove selected | remove selected |

MA refuses to move or delete items at or before the buffered index (`IndexError`, or a silent no-op for delete): the PL editor shows those rows normally and the marquee says "Music Assistant won't change a track that's already buffered" when the server refuses. The current row cannot be removed on a remote queue (MA's own UI hides it too).

Save as playlist is also in the Playback menu: **Playback › Save Queue as Playlist…** (any output; on This Mac with the local queue it falls back to the file panel, decision 4) and **Playback › Favorite Current Track ⌃⌘L** (`players/add_currently_playing_to_favorites` for a speaker or the Sendspin-fed Mac; for the local queue only when the current `Track` came from Music Assistant, which `Track.Source` cannot say today, so it is disabled for local files; decision 8). Both are disabled without the capability.

### 2.7 Empty, offline and error states

- Library not connected: unchanged (`LibraryStatusView`). Discover and Favorites sidebar items stay listed but their columns show the connection status like the others.
- Playlists list failed: `PagedListView`'s failure with Retry (unchanged). Detail failed: `TrackListView`'s (unchanged).
- A write failing with `.unreachable` reverts the optimistic change and posts "Can't reach Music Assistant"; the Library fallback (#0067) is **not** told about write failures (a write is not a browse; `reportFailure` already ignores `.notFound`/`.unsupported`; add `.backend` from writes).
- A write refused by the server (error frame): revert, show `details` verbatim in the bar (MA's messages are user-facing: "Playlist … is not editable", "Playlist positions start at 1").
- Server lacks a command (error_code 12): the capability is cleared for the session and the control disappears (reorder).
- Discover row with no items: "Nothing here yet" with the row's subtitle. Row fetch failure: the row shows Retry; other rows are unaffected.

### 2.8 Accessibility and keyboard

- Every new control has an `accessibilityIdentifier` in the existing scheme: `library.playlists.new`, `library.playlist.rename`, `library.playlist.delete`, `library.playlist.tracks`, `library.playlist.remove`, `library.favorites.<kind>`, `library.discover.<row>`, `library.track.favorite`, `playlist.load.picker`, `playlist.save.name`.
- Hearts: `accessibilityLabel("Favorite")`, value On/Off, toggle action; always visible to VoiceOver even when hover-hidden.
- Keyboard: ⌘N new playlist (Library key window), Return play, Delete remove (with the confirmation above), ⌘⌫ delete playlist, Space toggles favorite on the selected rows? No: Space is reserved for play/pause in the skinned windows; favorite is ⌘L in the Library window (Music.app's "Love"), ⌃⌘L app-wide for the current track.
- Drag-and-drop has menu equivalents everywhere (Add to Playlist ▸, Move Up/Move Down in the detail context menu when reorder is supported).
- Confirmation alerts use the standard `confirmationDialog` with a destructive role so VoiceOver announces them.

---

## 3. Architecture

### 3.1 `MusicBackendKit`: capabilities, models, API

Capabilities (static per backend; per-item flags carry the rest):

```swift
public static let playlistEditing   = BackendCapabilities(rawValue: 1 << 5) // create, rename, delete, add, remove
public static let favorites         = BackendCapabilities(rawValue: 1 << 6)
public static let recommendations   = BackendCapabilities(rawValue: 1 << 7) // Discover rows
public static let radio             = BackendCapabilities(rawValue: 1 << 8)
public static let queueEditing      = BackendCapabilities(rawValue: 1 << 9) // remote queue view + edits
public static let saveQueueAsPlaylist = BackendCapabilities(rawValue: 1 << 10)
```

Music Assistant: all of them. Folder: none (its queue is AudioCore's, handled locally as today; a later item could give the folder backend M3U playlists in the folder: `playlists` + `playlistEditing` writing `.m3u8` files next to the music, with `PlaylistFile` already serializing; favorites could be a local SQLite/JSON set. Plex is reached through MA's provider and needs nothing).

Models (`Models.swift`), all additive with defaults so current call sites compile:

```swift
public enum MediaKind { case artist, album, track, playlist, radio }       // + radio; exhaustive switches updated
public struct PlaylistEditing: OptionSet { addRemove, reorder, rename, delete }
public enum PlaylistSource: Hashable { case user, builtIn, provider(name: String) }
extension LibraryPlaylist {
    public var isEditable = false, isDynamic = false, owner: String?, source: PlaylistSource = .user
    public var editing: PlaylistEditing = []        // the backend fills it from flags + server features
    public var isFavorite: Bool? = nil
    public var libraryID: String?                    // db id for add/remove/export
}
extension LibraryTrack  { public var isFavorite: Bool? = nil; public var playlistPosition: Int? = nil }
extension LibraryAlbum, LibraryArtist { public var isFavorite: Bool? = nil }
public struct LibraryRadio: Identifiable { id: MediaID(.radio, uri), name, artwork }
public struct RecommendationRow: Identifiable { id: String (provider + "/" + item_id), name, subtitle?, icon: String?, isEnabledByDefault, kind: .shelf | .timeline }
public enum RecommendationItem: Identifiable { case artist(LibraryArtist), album(LibraryAlbum), track(LibraryTrack), playlist(LibraryPlaylist), radio(LibraryRadio), other(MediaID, name: String, artwork: ArtworkRef?) }
public struct QueueItem: Identifiable { id: String (queue_item_id), index: Int, title, artist: String?, album: String?, duration: TimeInterval?, item: MediaID?, artwork: ArtworkRef?, isAvailable }
public struct QueueSnapshot { output, items: [QueueItem], currentIndex: Int?, total: Int, isComplete: Bool }
public enum QueueEdit { case remove([String]), move(String, by: Int), moveToEnd(String), clear, play(index: Int) }
public enum FavoriteKind { case tracks, albums, artists, playlists, radios }
public enum LibraryChange: Hashable { case playlistAdded(MediaID), playlistUpdated(MediaID), playlistDeleted(MediaID), favoriteChanged(MediaID, Bool?), played }
```

`MusicBackend` additions, every one with a default implementation that throws `.unsupported(<capability>)` or returns an empty value, so `FolderBackend` and `StubMusicBackend` keep compiling:

```swift
func createPlaylist(named name: String) async throws -> LibraryPlaylist
func renamePlaylist(_ id: MediaID, to name: String) async throws
func deletePlaylist(_ id: MediaID) async throws
func add(_ items: [MediaID], toPlaylist id: MediaID) async throws        // tracks and albums
func remove(positions: [Int], fromPlaylist id: MediaID) async throws     // 1-based, from LibraryTrack.playlistPosition
func movePlaylistTrack(in id: MediaID, from: Int, to: Int) async throws  // 1-based
func saveQueueAsPlaylist(on output: OutputDevice.ID, named name: String) async throws
func exportPlaylist(_ id: MediaID) async throws -> String               // M3U8 (optional item)
func setFavorite(_ id: MediaID, _ on: Bool) async throws
func favoriteCurrentTrack(on output: OutputDevice.ID) async throws
func favorites(_ kind: FavoriteKind, page: PageRequest) async throws -> Page<AnyFavorite>   // or one method per kind
func recommendationRows() async throws -> [RecommendationRow]
func recommendationItems(_ row: RecommendationRow.ID) async throws -> [RecommendationItem]
func radios(page: PageRequest) async throws -> Page<LibraryRadio>
func queue(on output: OutputDevice.ID) async -> AsyncStream<QueueSnapshot>   // first snapshot, then one per change
func edit(_ edit: QueueEdit, on output: OutputDevice.ID) async throws
func libraryChanges() -> AsyncStream<LibraryChange>                     // default: a stream that finishes at once
```

`favorites(_:page:)`: simpler as five methods (`favoriteTracks(page:)` …) than a type-erased item; pick per kind. `play(_:on:mode:)` already takes `MediaID`s: `.radio` ids and Discover items pass through unchanged.

### 3.2 `MusicAssistantKit`: requests, decoding, mapping

`MARequest` builders (one per command, arg names from `commands.json`, tested in `MARequestEncodingTests`): `createPlaylist(name:provider:)`, `updatePlaylist(itemID:playlist: MAJSON, overwrite:)`, `removeLibraryItem(mediaType:libraryItemID:)`, `addPlaylistTracks(playlistID:uris:)`, `removePlaylistTracks(playlistID:positions:)`, `movePlaylistTrack(playlistID:from:to:)`, `exportPlaylist(playlistID:)`, `saveQueueAsPlaylist(queueID:name:)`, `addFavorite(uri:)`, `removeFavorite(mediaType:libraryItemID:)`, `addCurrentlyPlayingToFavorites(playerID:)`, `libraryItems(... favorite: Bool?)` (extend the existing builder), `recommendations()`, `recommendationItems(provider:itemID:)`, `recentlyPlayed(limit:)`, `queueDeleteItem(queueID:itemID:)`, `queueMoveItem(queueID:itemID:shift:)`, `queueMoveItemEnd`, `queueClear(queueID:)`, `queuePlayIndex(queueID:index:)`.

Decoding (`Models/MAMediaItems.swift`, `MAPlayers.swift`, new `MARecommendations.swift`): `MAPlaylist` gains `supportedMediatypes`, `position`, `access` (raw `MAJSON?`); `MATrack` gains `position: Int?`; `MARecommendationFolder` (`item_id`, `provider`, `name`, `subtitle`, `icon`, `type`, `enabled_by_default`, `supports_provider_filter`, `uri`); `MARecommendationItem` decoded by `media_type` (a tagged enum over the existing `MAArtist/MAAlbum/MATrack/MAPlaylist/MARadio/MAItemMapping`; unknown types → `.other`); `MARadio`; `MABackgroundTask` (`id`, `name`, `status`); `MAFavoriteUpdate`. `MAQueueItem.mediaItem` is raw `MAJSON` today; decode `media_item` as `MATrack?` leniently to get artist/album for the PL rows (`MANowPlayingMapper` already digs `artists[0].name` out; share that).

Mapping (`MAMapping.swift`): `LibraryPlaylist.init(ma:features:)` sets `source` (builtin + `owner == "Music Assistant"` → `.builtIn`; builtin otherwise → `.user`; other domains → `.provider(name)`), `editing` (`addRemove` when `is_editable && !is_dynamic`; `+ reorder` when the server has `move_playlist_track`; `rename`/`delete` unless `.builtIn`), `libraryID = item_id` when `provider == "library"`. `LibraryTrack.playlistPosition = position`, `isFavorite = favorite`.

URIs: `MAURI` grows `.radio` and `.folder` kinds (`library://radio/3`, `library://folder/recently_played`); `MediaID.rawValue` stays the URI.

### 3.3 `MusicAssistantBackend` additions

- Library id for `db_playlist_id`: from the `library://playlist/<id>` URI (`MAURI.itemID`), since every listed playlist is a library item. A provider URI (`spotify://playlist/…`) from a Discover row is resolved first with `music/item_by_uri` (gives the library item when in library) and refused with `.notFound` otherwise.
- `add(_:toPlaylist:)`: one `add_playlist_tracks` with the URIs (albums included: MA expands). Returns after the `BackgroundTask` frame; the model refetches on `media_item_updated` for the playlist uri or after a fallback delay (3.5).
- `remove(positions:…)`: positions as given (1-based from `playlistPosition`); never computed from row indexes.
- `movePlaylistTrack`: throws `.unsupported(.playlistEditing)` when the feature probe says absent (3.6).
- `setFavorite(on: true)`: `favorites/add_item {item: uri}`; `false`: `favorites/remove_item {media_type, library_item_id}` from the URI; a `library://` URI is required for remove (Discover items from providers go through `item_by_uri` first).
- `favoriteCurrentTrack(on:)`: `players/add_currently_playing_to_favorites` on the player (the Sendspin wrapper for This Mac, via `resolveLocalPlayer()`).
- `saveQueueAsPlaylist(on:named:)`: `queue_id` from `playerID(for:)` with the same leader redirect as `play`.
- `queue(on:)`: the same watcher pattern as `nowPlaying(on:)` (`MANowPlayingWatch`): first `player_queues/get` (for `current_index`, `items` count) plus `player_queues/items` pages, then refetch on `queue_items_updated`/`queue_updated` with the queue's id (`MAEventMatch.classify` already returns `.refetch` for `queue_items_updated`), debounced, plus a slow poll (30 s) as a safety net while events stay unverified. Stops when the subscriber cancels.
- `edit(_:on:)`: straight command calls; `.remove(ids)` sends one `delete_item` per id (highest `index` first, computed from the last snapshot); `.move(id, by:)` sends `move_item` with `pos_shift`.
- `libraryChanges()`: a broadcast built on `client.events()`: `media_item_*` with `object_id` (or `data.uri`) starting `library://playlist/` → the playlist cases; `favorite_updated` → `.favoriteChanged(uri, favorite)`; `media_item_updated` with `data.favorite` present → `.favoriteChanged`; `media_item_played` → `.played`. Buffered-newest, yields `[]` nothing while disconnected, restarts on reconnect (as `playbackActivity` does).
- Errors: `MusicAssistantError.server(code:details:)` → `MusicBackendError.backend(details)`; code 12 (`Invalid or unsupported command.`) → `.unsupported(...)` for the command's capability so the UI can hide the control; a `details` mentioning "scope" or "permission" → a new `MusicBackendError.forbidden(String)` so Rename/Delete can disable with that text (an additive case; `errorDescription` returns the message).

### 3.4 Observable models (`LibraryBrowser`)

Keep `LibraryBrowserModel` as the hub but put the new state in sibling `@MainActor @Observable` classes it owns, each in its own file so items can be worked in parallel:

- `PlaylistEditor` (`PlaylistEditor.swift`): the open playlist's rows and the structural edits. State: `rows: [LibraryTrack]`, `phase` (`idle/loading/loaded/failed`), `pending: PendingEdit?` (`.adding(n)`, `.removing(n)`, `.moving`, `.renaming`), `error: String?`. Methods: `load(_ playlist:)`, `remove(selected: Set<MediaID>)`, `move(from: IndexSet, to: Int)`, `add(_ items:)`, `rename(to:)`. Every edit: snapshot rows → apply locally → `await backend…` → on success schedule a refetch (3.5) → on failure restore the snapshot, set `error`. Serialized through one `Task` chain per editor (`queue: Task<Void, Never>?` continued with `Task { await previous?.value; … }`) so two quick removes never race, and a generation counter so a stale refetch never overwrites newer rows.
- `PlaylistsModel` (list-level ops: create, rename, delete; `recentTargets` for the submenu; the grouping) in `PlaylistsModel.swift`.
- `FavoritesModel` (`FavoritesModel.swift`): counts per kind, five `PagedList`s created lazily, `toggle(_ id:)` with optimistic flip stored in an `overrides: [MediaID: Bool]` map that the rows read (`isFavorite(for:)`), cleared when the refetch or a `favoriteChanged` event confirms.
- `DiscoverModel` (`DiscoverModel.swift`): `rows`, `hiddenByDefault`, `showAll` (UserDefaults `discover.showAllRows`), `items: [RecommendationRow.ID: LoadState<[RecommendationItem]>]`, per-row generation, `refresh(row:)`, `refreshAll()` debounced on `.played`.
- `QueueRows` (`LocalPlayback` or `LibraryBrowser`, `QueueRows.swift`): the PL window's source, a value type `enum QueueRows { case local([Track], current: Int?), remote(QueueSnapshot) }` plus pure helpers (`rowText`, `runningTime`, `indicesToRemove(for: crop)`). `PlaylistModel` (App) reads it instead of `player.queue.tracks` directly; the choice is made in `PlayerModel` from `selectedOutput`, `thisMacFeed` and the `queue(on:)` subscription (`QueueRowsSelection.choose(output:feed:)`, pure, tested).
- `LibraryBrowserModel` gains `favorites`, `discover`, `playlistsModel`, `playlistEditor`, the new sections (`LibrarySection` grows `favorites`, `radio`, `discover(rowID)`; `sections` is computed from capabilities + rows), and a `changes` task that forwards `libraryChanges()` to: `playlists.reload()` on added/deleted; `playlistEditor.reloadIfOpen(id)` on updated; `favorites.apply(change)`; `discover.scheduleRefresh()` on played. It starts in `appeared()` and stops in `disappeared()` like the other tasks.

### 3.5 Caching, refresh, optimistic updates

- Lists are cached by the existing `PagedList`s per section; `refresh()` reloads them. Playlist tracks are not cached across selections (as today) except the open one.
- After an own write: the editor refetches when `libraryChanges()` yields `playlistUpdated(id)` for that playlist, or after `refetchFallback` (2 s, injectable) if no event arrives, whichever first; while `pending != nil` structural edits are disabled, selection and playback are not. A `move` (synchronous server-side) refetches immediately on return.
- Rows keep their identity across refetches (`MediaID`), so selection survives; a removed row's selection is pruned.
- Positions: after a remove, positions above the removed ones shift; the optimistic local rows renumber `playlistPosition` (pure helper `PlaylistPositions.renumber(after removing:)`) so a second remove before the refetch is still correct, but it is disabled anyway while pending (belt and braces).
- Favorites: the override map approach above; `LibraryTrack.isFavorite` in cached lists is patched in place on confirmation (`PagedList.update(id:_:)`, a small addition).
- Discover: rows are fetched on first show and kept for the session; random rows refresh on explicit Refresh or `.played` (debounced 1.5 s, matching MA's UI).
- Remote queue: `QueueSnapshot` replaced wholesale per refetch; the PL window's scroll position and selection (by `queue_item_id`) survive.

### 3.6 Server feature detection

`move_playlist_track` is absent on 2.10.6. Two layers:

1. **Probe at connect** (recommended): `GET <base>/api-docs/commands.json` (no auth, already documented in the notes; the HTTP transport exists for artwork) once per `(server_id, server_version)`, parse only the `command` names into `MAServerCommands: Set<String>`, cached in memory for the backend's life. `commands.json` is 310 entries, about 200 KB; fine once per connect; on failure the set is empty and nothing optional is offered. The probe is behind `MAServerCommands.probe(transport:base:)` and tested with a fixture made from `docs/ma-protocol/commands.json` trimmed to names (`commands-names.json`).
2. **Error code 12 at use**: any `Invalid or unsupported command.` marks the command absent for the session and maps to `.unsupported`.

`LibraryPlaylist.editing` carries the result so views never see server details.

### 3.7 Concurrency

- Backend methods are `actor` methods as today; long streamed `playlist_tracks` keeps its 60 s timeout; writes use the default timeout.
- The editor's serialized task chain plus generation counters (the pattern of `LibraryBrowserModel.loadTracks`) is the only ordering mechanism; no locks.
- `libraryChanges()`/`queue(on:)` streams are `bufferingNewest(1)` and end on subscriber cancellation; `disappeared()` cancels them so a closed Library window costs nothing.
- The PL window's remote subscription lives in `PlayerModel` next to `observeNowPlaying()` and follows `selectedOutput` and `thisMacFeed`.

### 3.8 Testing strategy

No network in tests. Three layers:

- **Pure helpers** (`LibraryBrowserTests`, `MusicBackendKitTests`): `PlaylistGrouping`, `PlaylistEditPolicy` (which actions for which flags/features), `PlaylistPositions` (renumber, positions of a selection, reverse order), `AddToPlaylistMenu.entries` (recent-first, excludes read-only and the open playlist), `QueueRowsSelection.choose`, `QueueRows` text helpers, `DiscoverRows.visible`, `MDIIcon.symbol`.
- **Backend against the stub socket** (`MusicAssistantKitTests`): `StubWebSocketTransport` + `FixtureScript` routes: assert the sent frame for each command (`MARequestEncodingTests`), decode recorded or synthetic responses (`ModelDecodingTests`), and behavior tests (`BackendPlaylistTests`: remove sends the rows' positions not indexes; reorder throws `.unsupported` when the probe lacks the command; a code-12 error flips the capability; add passes album URIs through; favorites remove needs a library id; `libraryChanges` maps the three event forms; `queue(on:)` refetches on `queue_items_updated` for its id only).
- **Models with `StubMusicBackend`** (`LibraryBrowserTests`): `StubMusicBackend` gains the new methods with recorded `calls`, gates and errors like the existing ones, plus a `changes` continuation tests can push into: optimistic remove and rollback on failure, serialized edits, stale refetch dropped, favorites override cleared on confirmation, Discover row failure isolated, sections follow capabilities.

The App target has no tests: keep every decision in the packages (as the project already does) and the views thin.

---

## 4. Decomposition into work items

Titles are declarative, bug-style. All are **fast tier** (nothing under `SkinLibrary` or `AudioCore` real-time paths; `QueueRows` reads `Track` values only). "Parallel" lists items that touch disjoint files and can run at the same time; W1 is the shared base and should land first (it is small). Issue numbers are the orchestrator's.

| # | Title | Depends on | Parallel with |
|---|---|---|---|
| W0 | Playlist, favorites, recommendation and queue responses are unrecorded | — (user's host) | everything |
| W1 | Playlists don't say whether they are editable, built-in or from a provider | — | W9 |
| W2 | Playlists can't be created, renamed or deleted | W1 | W4a, W5, W7a, W8, W9 |
| W3 | Tracks can't be added to a playlist from the Library, and "Add to Playlist" means the queue | W2 | W4, W5, W7a, W8 |
| W4a | SkinAmp can't tell which playlist commands the server has | — | all |
| W4 | Playlist tracks can't be removed or reordered | W1, W4a | W3, W5, W7, W8 |
| W5 | The Library doesn't follow playlist and favorite changes made elsewhere | W1 | W2, W3, W4, W7, W8 |
| W6 | The current queue can't be saved as a playlist | W1 | W4, W7, W8 |
| W7a | Tracks, albums and playlists can't be favorited | W1 | W2–W6, W8 |
| W7b | There is no Favorites section in the Library | W7a | W2–W6, W8 |
| W8 | Music Assistant's automatic playlists (Discover rows) aren't in the Library | W1 | W2–W7 |
| W9 | The playlist editor window is empty when a speaker is selected | — | W1–W8 |
| W10 | Queue rows can't be removed, moved or cleared from the playlist editor on a speaker | W9 | W2–W8 |
| W11 | The playlist editor's LIST › Load and Save don't use Music Assistant playlists | W6, W9 | W4, W7, W8 |
| W12 | Radio stations aren't in the Library (optional) | W1, W7a | — |
| W13 | Playlists can't be exported or imported as M3U (optional) | W2 | — |

### W0 Playlist, favorites, recommendation and queue responses are unrecorded

Scope: the recipe in 1.5: extend `scripts/record-ma-fixtures.py` (`ALLOWED` reads; `--record-playlist-writes` with its own allowlist, throwaway playlist, favorite restore, `finally` cleanup, `events-playlists.json`), `MAFixture` cases for the new files, `ModelDecodingTests` for each, a notes section in `docs/ma-protocol-notes.md`. The user runs both commands on the host; agents never do. Files: `scripts/record-ma-fixtures.py`, `Packages/PlayerKit/Sources/MusicAssistantKitStub/MAFixture.swift`, `Fixtures/*.json`, `Tests/MusicAssistantKitTests/ModelDecodingTests.swift`, `docs/ma-protocol-notes.md`. Tests: the script's `--check` gate; decode tests. Needs the user's Mac: file it first, let the rest proceed on synthetic routes, re-verify decoders when the recording lands.

### W1 Playlists don't say whether they are editable, built-in or from a provider

Scope: `MediaKind.radio`; `LibraryPlaylist` fields (`isEditable`, `isDynamic`, `owner`, `source`, `editing`, `isFavorite`, `libraryID`), `LibraryTrack.playlistPosition/isFavorite`, `LibraryAlbum/Artist.isFavorite`, `PlaylistEditing`, `PlaylistSource`; `MAPlaylist`/`MATrack` decoding of `position`, `supported_mediatypes`; `MAMapping` rules; `PlaylistGrouping`; the grouped Playlists list with the read-only badge and "∞"; the detail header line (source, owner, Read-only/Dynamic). No writes yet. Files: `MusicBackendKit/Models.swift`, `MusicAssistantKit/MAMapping.swift`, `Models/MAMediaItems.swift`, `MAURI.swift`, new `LibraryBrowser/PlaylistGrouping.swift`, `App/Browser/ArtistListView.swift` (`PlaylistListView`), `App/Browser/TrackListView.swift`. Tests: `ModelDecodingTests.playlistDecodesEditableOwnerAndSource` (from `playlists-page.json`: built-in rows are `.builtIn`, `isEditable == false`), `MAMappingTests.builtinUserPlaylistIsEditableUser`, `PlaylistGroupingTests` (order, provider group naming, read-only suffix). Fast.

### W2 Playlists can't be created, renamed or deleted

Scope: backend API `createPlaylist/renamePlaylist/deletePlaylist` + defaults; `MARequest` builders; `MusicAssistantBackend` implementations (rename sends the fetched playlist object with the new name and `overwrite: true`; delete uses `music/library/remove_item`; built-in refused client-side); `MusicBackendError.forbidden`; `PlaylistsModel` (create → insert and select, rename inline with rollback, delete with rollback); UI: `[+]` toolbar button, name sheet, inline rename, context menu, delete confirmation, ⌘N / ⌘⌫; `StubMusicBackend` methods. Files: `MusicBackendKit/MusicBackend.swift`, `Models.swift`, `MusicAssistantKit/MARequest.swift`, `MusicAssistantBackend.swift` (new extension file `MusicAssistantBackend+Playlists.swift` to keep the 835-line actor readable), new `LibraryBrowser/PlaylistsModel.swift`, `LibraryBrowserModel.swift`, `MusicBackendStub/StubMusicBackend.swift`, `App/Browser/ArtistListView.swift`, new `App/Browser/PlaylistNameSheet.swift`, `App/Browser/LibraryWindowView.swift` (toolbar). Tests: `MARequestEncodingTests.playlistCommandsUseTheDocumentedArgNames`, `BackendPlaylistTests.createReturnsAnEditableUserPlaylist`, `.renameSendsTheWholePlaylistWithOverwrite`, `.deleteUsesLibraryRemoveItem`, `.deleteRefusesBuiltIn`, `.scopeErrorMapsToForbidden`; `PlaylistsModelTests.createInsertsAndSelects`, `.renameRollsBackOnFailure`, `.deleteRollsBackOnFailure`. Fast.

### W3 Tracks can't be added to a playlist from the Library, and "Add to Playlist" means the queue

Scope: rename the queue item to "Add to Queue" in `LibraryPlaybackActions` (all three modifiers); `add(_:toPlaylist:)` API + MA (`add_playlist_tracks`, album URIs pass through); `AddToPlaylistMenu.entries` (recent-first, editable only, excludes the open playlist, trailing "New Playlist…"); the submenu in track and album context menus (album tracks, artist albums, all albums, search, playlist detail, Discover later); recent targets in UserDefaults; the marquee notice; drag-and-drop of tracks/albums onto playlist rows and into the open editable playlist (`MediaIDTransfer`); `StubMusicBackend.add`. Files: `App/Browser/LibraryPlaybackActions.swift`, new `App/Browser/AddToPlaylistMenu.swift` (view) and `LibraryBrowser/AddToPlaylistMenu.swift` (pure entries), `MusicBackendKit` (+ `MediaIDTransfer` in `MusicBackendKit` so the PL window can share it), `MusicAssistantBackend+Playlists.swift`, `PlaylistsModel.swift`, `App/Browser/ArtistListView.swift` (drop target), `App/PlayerModel.swift` (notice helper). Tests: `AddToPlaylistMenuTests` (ordering, exclusions, empty state), `BackendPlaylistTests.addSendsAlbumAndTrackURIsUnchanged`, `.addToReadOnlyPlaylistIsRefused`, `PlaylistsModelTests.addRecordsRecentTarget`. Fast.

### W4a SkinAmp can't tell which playlist commands the server has

Scope: `MAServerCommands` (probe `GET /api-docs/commands.json` through `MAHTTPTransport`, parse names only, cache per server identity, empty on failure), called from `connect()` after the handshake (non-blocking: `Task` that fills a `serverCommands` property; `LibraryPlaylist.editing` is computed at mapping time, so the Playlists list simply reloads on `refresh`, or the probe completes before the first list in practice); code-12 handling that removes a command for the session; `commands-names.json` fixture derived from `docs/ma-protocol/commands.json`. Files: new `MusicAssistantKit/MAServerCommands.swift`, `MusicAssistantBackend.swift` (connect + error mapping), `MusicAssistantKitStub/StubHTTPTransport.swift` (route), `Fixtures/commands-names.json`. Tests: `ServerCommandsTests.probeParsesNamesFromTheRecordedList` (asserts `move_playlist_track` is absent and `save_as_playlist` present), `.probeFailureYieldsNoCommands`, `BackendPlaylistTests.unsupportedCommandErrorClearsTheFeature`. Fast. Fully parallel (new files).

### W4 Playlist tracks can't be removed or reordered

Scope: `remove(positions:fromPlaylist:)`, `movePlaylistTrack`; `PlaylistEditor` (optimistic remove/move, serialized chain, generations, pending bar state, rollback, refetch via W5's change or the fallback delay: until W5 lands, the fallback delay alone); `PlaylistPositions` helpers; detail UI: Delete key with the 10+ confirmation, "Remove from Playlist" context item, drag-to-reorder `onMove` gated on `editing.reorder`, Move Up/Down items, the one-shot "needs a newer Music Assistant" caption, the transient bar with Retry; `StubMusicBackend` methods. Files: `MusicBackendKit/MusicBackend.swift`, new `LibraryBrowser/PlaylistEditor.swift`, `PlaylistPositions.swift`, `MusicAssistantBackend+Playlists.swift`, `MARequest.swift`, `App/Browser/TrackListView.swift` (split a `PlaylistTracksView` out of it), new `App/Browser/PlaylistEditBar.swift`. Tests: `PlaylistPositionsTests` (selection → positions, descending order, renumber after remove), `PlaylistEditorTests` (`removeAppliesAtOnceAndSends`, `removeRollsBackOnFailure`, `editsRunInOrder`, `staleRefetchIsDropped`, `moveIsRefusedWithoutReorder`, `pendingBlocksASecondStructuralEdit`), `BackendPlaylistTests.removeSendsOneBasedPositions`, `.moveSendsFromAndTo`, `.moveThrowsUnsupportedWithoutTheCommand`. Fast.

### W5 The Library doesn't follow playlist and favorite changes made elsewhere

Scope: `LibraryChange`, `libraryChanges()` with the default empty stream; MA implementation over `client.events()` (three event forms, restart on reconnect, lenient `object_id`/`data.uri`); `LibraryBrowserModel.changes` task wiring (reload playlists on add/delete, editor reload on update, favorites apply, discover refresh hook); `StubMusicBackend.pushChange`. Files: `MusicBackendKit/Models.swift`, `MusicBackend.swift`, new `MusicAssistantKit/MALibraryChanges.swift`, `MusicAssistantBackend.swift` (subscription plumbing like `playbackActivity`), `LibraryBrowserModel.swift`, `StubMusicBackend.swift`. Tests: `LibraryChangesTests` (pure classifier: `media_item_deleted` on `library://playlist/4` → `.playlistDeleted`; `favorite_updated` → `.favoriteChanged`; `media_item_updated` with `favorite` → `.favoriteChanged`; non-playlist uris ignored; missing `object_id` falls back to `data.uri`), `BackendLibraryChangesTests.streamRestartsAfterReconnect`, `LibraryBrowserModelTests.playlistAddedElsewhereReloadsTheList`. Fast. Note for #0076: the recorded `events-playlists.json` from W0 becomes this item's fixture when it exists.

### W6 The current queue can't be saved as a playlist

Scope: `saveQueueAsPlaylist(on:named:)` API + MA (`player_queues/save_as_playlist` with the leader redirect; `QueueEmpty` → a clear notice); Playback › Save Queue as Playlist… with the name sheet (shared with W2's sheet view), falling back to the file panel for the local queue (decision 4); notice and Playlists reload on success. Files: `MusicBackend.swift`, `MARequest.swift`, `MusicAssistantBackend+Playlists.swift`, `App/PlaybackCommands.swift`, `App/PlayerModel+PlaylistFiles.swift` (a `saveQueue()` that picks file vs. MA via a pure `QueueSaveTarget.choose(output:feed:capabilities:)` in `LibraryBrowser`), `StubMusicBackend`. Tests: `QueueSaveTargetTests` (local queue → file; speaker → MA; This Mac on MA feed → MA; folder backend on a speaker → refusal), `BackendPlaylistTests.saveQueueTargetsTheLeaderQueue`, `.saveQueueOnAnEmptyQueueIsAClearError`. Fast.

### W7a Tracks, albums and playlists can't be favorited

Scope: `setFavorite`, `favoriteCurrentTrack(on:)` API + MA; hearts in `TrackRow`, `AlbumRow`, artist rows and playlist rows (hover-visible, VoiceOver always); Favorite/Unfavorite in every context menu; ⌘L in the Library window; Playback › Favorite Current Track ⌃⌘L (enabled per decision 8); `FavoritesModel.toggle` with the override map and confirmation via W5 (or refetch fallback); `PagedList.update(id:_:)`. Files: `MusicBackend.swift`, `MARequest.swift`, new `MusicAssistantBackend+Favorites.swift`, new `LibraryBrowser/FavoritesModel.swift`, `PagedList.swift`, new `App/Browser/FavoriteButton.swift`, `TrackListView.swift`, `AlbumListView.swift`, `ArtistListView.swift`, `LibraryPlaybackActions.swift`, `PlaybackCommands.swift`, `PlayerModel.swift`. Tests: `FavoritesModelTests` (`toggleFlipsAtOnce`, `failureRestores`, `confirmationClearsOverride`, `changeFromElsewhereUpdatesRows`), `BackendFavoritesTests.addSendsTheURI`, `.removeNeedsALibraryID`, `.favoriteCurrentTrackUsesThePlayer`, `PagedListTests.updatePatchesAnItemInPlace`. Fast.

### W7b There is no Favorites section in the Library

Scope: `LibrarySection.favorites`, counts (`*/count {favorite_only: true}`) and five paged lists (`library_items {favorite: true}`), the kinds column and the detail lists reusing `PagedListView`/`AlbumListView`/`TrackRow` with the W7a hearts; album rows push tracks; unfavorite removes after refetch. Files: `LibraryBrowserModel.swift` (sections), `FavoritesModel.swift`, `MusicAssistantBackend+Favorites.swift`, `MARequest.swift` (`libraryItems(favorite:)`, `count(favoriteOnly:)`), `App/Browser/LibrarySidebarView.swift`, new `App/Browser/FavoritesView.swift`, `LibraryWindowView.swift`. Tests: `MARequestEncodingTests.favoriteListingsPassTheFilterToCountToo`, `FavoritesModelTests.countsLoadPerKind`, `LibraryBrowserModelTests.favoritesSectionNeedsTheCapability`. Fast.

### W8 Music Assistant's automatic playlists (Discover rows) aren't in the Library

Scope: `RecommendationRow/Item`, `recommendationRows/items` API + MA decoding (`MARecommendationFolder`, tagged item decoding, `ItemMapping` fallback), `DiscoverModel` (rows, hidden-by-default, Show all rows, per-row load/refresh/failure isolation, `.played` debounce), `MDIIcon.symbol`, sidebar "Discover" group with rows, the row items view with Play All / Refresh / context actions (Add to Playlist via W3's menu when present, else without it), `item_by_uri` resolution for mappings when played or favorited. Files: `MusicBackendKit/Models.swift`, `MusicBackend.swift`, new `MusicAssistantKit/Models/MARecommendations.swift`, new `MusicAssistantBackend+Discover.swift`, `MARequest.swift`, new `LibraryBrowser/DiscoverModel.swift`, `DiscoverRows.swift`, `MDIIcon.swift`, `LibraryBrowserModel.swift`, `App/Browser/LibrarySidebarView.swift`, new `App/Browser/DiscoverView.swift`, `LibraryWindowView.swift`. Tests: `ModelDecodingTests.recommendationFolderDecodes`, `.recommendationItemsDecodeByMediaType` (synthetic until W0), `DiscoverRowsTests` (hidden by default, show all, order preserved), `DiscoverModelTests` (`rowFailureLeavesOthersLoaded`, `staleRowResultDropped`, `playedRefreshIsDebounced`), `MDIIconTests.unknownIconFallsBack`. Fast.

### W9 The playlist editor window is empty when a speaker is selected

Scope: `QueueItem/QueueSnapshot`, `queue(on:)` API + MA watcher (`player_queues/get` + paged `items`, refetch on queue events for the id, slow poll, cap per decision 10), `MAQueueItem.media_item` lenient `MATrack` decode; `QueueRows` and `QueueRowsSelection.choose` (local vs. remote by output and feed); `PlayerModel` subscription following `selectedOutput`/`thisMacFeed`; `PlaylistModel` reads `QueueRows` (rows, current, running time, shade text, HTML export, File Info for a remote item); double-click/Return → `play_index` through `edit(.play(index:))`. Read-only otherwise: REM/MISC entries no-op with the marquee notice on a remote queue (W10 adds the edits). Files: `MusicBackendKit/Models.swift`, `MusicBackend.swift`, new `MusicAssistantKit/MAQueueWatch.swift`, `MusicAssistantBackend.swift` (`queue(on:)`), `MARequest.swift`, new `LibraryBrowser/QueueRows.swift`, `App/Playlist/PlaylistModel.swift`, `App/PlayerModel.swift`, `App/Playlist/PlaylistWindowView.swift` (`run`), `StubMusicBackend`. Tests: `QueueRowsSelectionTests` (This Mac + local → local; This Mac + MA feed → remote wrapper; speaker → remote leader; folder backend + speaker → empty), `QueueRowsTests` (row text from a queue item with and without artist, running time, crop indices), `BackendQueueTests.queueSnapshotPagesItems` (synthetic 2-page route), `.queueRefetchesOnItsOwnQueueEventsOnly`, `ModelDecodingTests.queueItemDecodesItsTrack` (needs W0's loaded-queue capture; synthetic until then). Fast.

### W10 Queue rows can't be removed, moved or cleared from the playlist editor on a speaker

Scope: `QueueEdit` + `edit(_:on:)` API + MA; PL REM (remove selected, crop, remove all), LIST › New (clear), single-row drag → `move_item(pos_shift)`, Delete key; refusals: multi-row drag, current row, buffered rows (server `IndexError` → marquee text), MISC sort disabled; optimistic snapshot edits with rollback via `QueueRows`. Files: `MusicBackend.swift`, `MARequest.swift`, `MusicAssistantBackend.swift`, `LibraryBrowser/QueueRows.swift` (`QueueEditPlan`: which deletes, in which order, from a selection), `App/Playlist/PlaylistModel.swift`, `PlaylistWindowView.swift`, `PlaylistContextMenus.swift`, `StubMusicBackend`. Tests: `QueueEditPlanTests` (descending delete order, crop complement, current row excluded, multi-row move refused), `BackendQueueTests.deleteSendsOnePerRowHighestFirst`, `.moveSendsPosShift`, `.clearUsesQueueClear`, `.bufferedRefusalIsAClearError`. Fast.

### W11 The playlist editor's LIST › Load and Save don't use Music Assistant playlists

Scope: LIST › Save on a remote queue → W6's name sheet → `save_as_playlist`; LIST › Load on a remote queue (or This Mac on the MA feed) → a playlist picker sheet (grouped list from `PlaylistsModel`, search, Load plays with replace); local queue keeps the file panels. The `run` switch in `PlaylistWindowView` routes by `QueueSaveTarget`/`QueueRowsSelection`. Files: `App/Playlist/PlaylistWindowView.swift`, `App/PlayerModel+PlaylistFiles.swift`, new `App/Playlist/PlaylistPickerSheet.swift`, `LibraryBrowser/QueueSaveTarget.swift` (extend with `load`). Tests: `QueueSaveTargetTests.loadFollowsTheSameChoice`. Fast. Mostly App code; the testable rule is the target choice.

### W12 Radio stations aren't in the Library (optional)

Scope: `LibraryRadio`, `radios(page:)`, `MARadio` decoding, Radio section (list + play + favorite), "Add Radio URL…" in the section's toolbar (`builtin/add_radio`) and PL ADD › URL mapping to it when the source is MA. Files: models, `MusicAssistantBackend+Radio.swift`, `LibraryBrowserModel.swift`, new `App/Browser/RadioListView.swift`, `PlaylistWindowView.swift`. Tests: decode, request encoding, section gating. Fast. Deferred unless the user wants it (decision 12).

### W13 Playlists can't be exported or imported as M3U (optional)

Scope: context "Export as M3U8…" (`export_playlist` → save panel; the M3U refers to server paths, say so in the panel message) and Library "Import Playlist…" (`import_playlist` with `library_matching: true`). Files: `MusicAssistantBackend+Playlists.swift`, `PlaylistsModel.swift`, `ArtistListView.swift`, `PlayerModel+PlaylistFiles.swift`. Fast. Deferred (decision 13).

Parallel plan: W1 → {W2+W3 (one implementer, shared `PlaylistsModel`), W4a, W5, W7a, W8, W9} → {W4, W6, W7b, W10} → {W11} → {W12, W13 if wanted}. W0 runs whenever the user has ten minutes at the host; its fixtures slot into W1/W5/W8/W9 decode tests as they land. Two implementations never share a working tree (Issues.md), so "parallel" means planned and reviewed in any order with no file conflicts, and the orchestrator's usual one-at-a-time implementation.

---

## 5. Open decisions (with recommended defaults)

1. **Reorder on 2.10.6 (no `move_playlist_track`).** Options: hide drag and the Move items (recommended; a one-shot caption explains); emulate with remove + re-add (impossible: add appends only); ask the user to update MA. Default: hide.
2. **How to detect server commands.** `GET /api-docs/commands.json` at connect (recommended: no auth, one request, exact) vs. try-and-cache error 12 only. Default: both, probe first.
3. **"Add to Playlist" on artists.** MA's own UI allows tracks, albums, radio, episodes, audiobooks; adding an artist would mean SkinAmp fetching every album and expanding client-side (many calls, hundreds of tracks). Default: tracks and albums only; artists get Play and Add to Queue as today.
4. **LIST › Save and Playback › Save Queue as Playlist on This Mac playing the local queue.** Keep the file panel (recommended: those are local files MA may not know; `PlaylistFile` already handles them) vs. a chooser sheet "Save as file… / Save to Music Assistant…" (MA needs URIs it knows; local files from the folder backend have none). Default: file; MA only when the queue shown is an MA queue.
5. **Delete command.** `music/library/remove_item` (`library.write`, what MA's UI calls) vs. `music/playlists/remove` (`library.manage`). Default: `remove_item`; a scope error disables Delete with the server's text.
6. **Where built-in playlists live.** Playlists › Built-in group (recommended: they are playlists in MA and in the recorded listing) vs. the Discover group. Default: Playlists › Built-in; hide-on-delete not offered.
7. **Discover rows shown.** Follow MA's `enabled_by_default` with a local "Show all rows" toggle (UserDefaults; MA stores its own choice in the user's `preferences`, which SkinAmp could read later via `auth/me` but it is the web app's layout, not a shared setting). Default: local toggle.
8. **Favorite Current Track on This Mac with the local queue.** `Track.Source` has only `.file(URL)`, so local tracks that came from MA are indistinguishable from files. Default: disabled for the local queue; enabled for speakers and the Sendspin-fed Mac. A later item could add a `.musicAssistant(uri)` origin to `Track` (touches `QueueStore` decoding) if the user wants hearts while playing locally.
9. **Dislikes.** `favorite: false` exists on `dev`. Default: treat `false` as not favorited, never send a dislike; no UI.
10. **Remote queue size in the PL window.** Default: load up to 2,000 items (4 pages of 500) and show "2,000 of 5,340 shown" in the running-time strip beyond that; larger queues are rare and MA itself slows above ~1,000 (notes). Alternative: window-driven paging around the visible range.
11. **Playlist tracks beyond 1,000.** Keep loading everything (the stream already chunks; 2.10.6 has no paging args). Default: load all; show a spinner with "Loading 1,500 tracks…" from the chunk count.
12. **Radio (W12).** In this milestone or later. Default: later, unless the user listens to radio through MA.
13. **Import/export (W13).** Default: later; export is cheap if wanted.
14. **The write-capture run (W0, step 2).** It creates and deletes a throwaway playlist on the user's server and briefly favorites one track (restored). Default: yes, once, with the user watching; the recorded `media_item_*` frames also settle #0076's envelope.
15. **Grouping of provider playlists.** One group per provider with "· read-only" when nothing in it is editable (recommended) vs. one "Read-only" group. Default: per provider; the user's server has only `builtin` and `filesystem_smb` today, so this matters only once a streaming provider is added.

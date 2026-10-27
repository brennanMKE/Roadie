# Genres (Music Assistant)

Design for [#0220](../../issues/0220.md), milestone M17: a Genres section in the Library window, a genre's albums, artists and tracks, and playing or shuffling a whole genre. Written 2026-10-27 against the user's server (Music Assistant 2.10.6, schema 65; commands from `docs/ma-protocol/commands.json`, schemas from `docs/ma-protocol/openapi.json`) and a read-only look at it the same day (#0220). Section 7 turns this into child issues #0222–#0225.

Non-goals: editing genres (`add`, `merge`, `update`, `remove`, aliases, exclusions, `scan_mappings`, `restore_defaults`: all `library.manage`), genre overview rows (`music/genres/overview`), genres on the folder library (§4.4), genres in search results, a genre filter on the Artists/Albums lists, and podcast or audiobook genres (§6, question 1).

---

## 1. What the server has

### 1.1 The user's library (#0220, 2026-10-27)

- `music/genres/count` → **113**. `music/genres/library_items {limit: 100, offset: 0}` → **99** items, not 100 (§3).
- Most genres are empty. `music/genres/media_counts {genre_ids}` gives counts per media type; about 30 genres have music. The largest: Classical (649 tracks, 3 artists, 2 playlists), Experimental (575 tracks, 5 albums), Electronic (403 tracks, 39 albums, 33 artists), Rock (266 tracks, 83 albums, 64 artists), Punk (230 tracks, 63 albums, 50 artists), Dance (215 tracks), Pop (65 tracks, 33 albums, 32 artists), Christmas Music (49), Soundtrack (25).
- Many genres are podcast and audiobook categories (Business, True Crime, Self Help, …). Seven names appear twice with different ids: Business 61/81, Comedy 13/62, History 67/88, Science 73/94, Sports 75/97, Technology 76/98, Religion & Spirituality 72/92. These names are the ones podcast and audiobook taxonomies share, so the pairs are most likely one podcast genre and one audiobook genre (the `Genre` schema has a `content_type`; §1.3). None of them has content today.
- Summary item keys (`summary` defaults to true): `available, external_ids, favorite, genre_alias_count, is_playable, item_id, media_type, metadata, name, provider, provider_mappings, sort_name, uri, version`. The full item (`summary: false`) adds, per the schema, `translation_key`, `content_type` (`null` for music, else `podcast`/`audiobook`) and `genre_aliases`.

So the counts show what a list of "genres with music" has to look like: about 30 rows out of 113, Classical first.

### 1.2 Commands (all `library.read`)

| Command | Args (exact names) | Returns | Roadie uses it for |
|---|---|---|---|
| `music/genres/library_items` | `limit`, `offset`, `order_by`, `favorite`, `search`, `provider`, `played_only`, **`hide_empty`** ("only applies when `media_type` is not set"), **`media_type`** ("return all genres (including non-defaults) that have at least one mapping for this media type; takes precedence over `hide_empty`"), **`content_type`** (`"music"`, `"podcast"`, `"audiobook"`; composes with `hide_empty`), `summary` | bare `[Genre]`, no total | the list |
| `music/genres/count` | `favorite_only` | int | not used for paging (§3) |
| `music/genres/media_counts` | `genre_ids: [String]` (required) | `{genre_id: {media_type: count}}` (exact key names unrecorded) | counts, ordering, "has music" |
| `music/genres/get` | `item_id`, `provider_instance_id_or_domain` | `Genre` | not needed for the UI; recorded once |
| `music/genres/tracks` / `albums` | `item_id` (one genre), `limit` (0 = unlimited), `offset`, `order_by` (e.g. `"random"`) | `[Track]` / `[Album]` | fallback for play (§4.3) |
| `music/genres/overview` | `item_id`, `provider_instance_id_or_domain?`, `limit?` | `[RecommendationFolder]` | not used (non-goal); recorded once |
| `music/genres/genres_for_media_item` | `media_type`, `media_id` | `[Genre]` | not used; recorded once to see a mapping |
| `music/genres/global_exclusions` | none | `[object]` | the 99-of-113 probe |
| `music/genres/scanner_status` | none | object | the probe (is a scan running?) |
| `music/{artists,albums,tracks,playlists}/library_items` | the usual paging plus **`genre: int | [int]`** | bare arrays | a genre's albums, artists, tracks |
| `player_queues/play_media` | `queue_id`, `media` (a `Genre` or a URI string is accepted by the schema), `option`, **`shuffle: Bool`** ("only applies to the options that start playing right away (play/replace)") | `null` | Play / Shuffle a genre |

`library_items` with a `genre` filter takes ids as **integers**; `media_counts` takes them as **strings**. `music/{tracks,albums,artists}/count` take no genre filter, so a genre's totals come from `media_counts`.

### 1.3 Model

`Genre` (openapi): `item_id`, `provider` (`"library"`), `name`, `sort_name`, `uri` (`library://genre/<id>`), `provider_mappings`, `metadata`, `favorite`, `is_playable`, `media_type: "genre"`, `content_type`, `genre_aliases`, `translation_key`. An alias is another spelling the scanner maps onto the genre (a tag "Electronica" onto Electronic); Roadie only shows the genre's `name`.

---

## 2. UX

### 2.1 Sidebar

Genres goes right after Albums, before Playlists: it is another way to browse the same library, like Artists and Albums, and the Music Assistant web app's "Browse by Genre" row sits with the library views.

```
┌ Library ─────────────┐
│   🎤 Artists         │
│   ▣ Albums           │
│   🎸 Genres          │   ← only with .genres (Music Assistant)
│   ♪≡ Playlists       │
│   ♥ Favorites        │
│   ((•)) Radio        │
│ DISCOVER …           │
└──────────────────────┘
```

Symbol `guitars` (SF Symbols 2, macOS 11+; the target is 14). `LibrarySection.genres` joins `sections` only when the backend has `BackendCapabilities.genres`, the same gate as `.radio`. AXID `library.sidebar.genres`.

### 2.2 Genres list (content column)

```
┌ Genres ─────────────────────────┐
│ Classical                   649 │
│ Experimental                575 │
│ Electronic                  403 │
│ Rock                        266 │
│ Punk                        230 │
│ Dance                       215 │
│ Pop                          65 │
│ Christmas Music              49 │
│ Soundtrack                   25 │
│ …                               │
└─────────────────────────────────┘
```

- **Only genres with music**: tracks + albums + artists > 0 from `media_counts`. Playlists alone don't count (a genre whose only items are playlists has nothing to show in the detail, §2.3).
- **Ordered by size**: track count descending, then album count descending, then `sort_name` (case- and diacritic-insensitive) ascending. Stable, so a refresh doesn't shuffle equal rows.
- **The count** is the track count, trailing, secondary, monospaced digits, like the Playlists and Favorites counts. The row's help tag spells it out: "649 tracks · 3 artists" (only non-zero parts, singular/plural right). The accessibility label is "Classical, 649 tracks".
- **Duplicate names merged**: genres whose names match case- and diacritic-insensitively (after trimming) become one row. Its counts are the sums (an overcount only if one item is mapped to both, which can't happen within one taxonomy; good enough for a list label), its members are every id, and its lists query all ids at once (`genre: [61, 81]`). With `content_type: "music"` the known duplicates are gone anyway (§1.1); merging stays because it is cheap and the server can create a second "Rock" from a tag spelled differently.
- The whole list is loaded at once (it's about 30 rows after filtering, at most a few hundred before), so no paging in the view: a plain `List` with selection, not `PagedListView`.
- States: loading (a `ProgressView`), failed (the error with Retry, as the other sections do), empty ("No genres with music": a library whose scanner hasn't mapped anything).
- Selecting a row opens it in the detail column. Double-click plays the genre (the same as Play, §2.4). Context menu: **Play**, **Shuffle**, **Play Next**, **Add to Queue**. No Add to Playlist (`add_playlist_tracks` takes track and album URIs, not genres) and no Favorite (genre favorites aren't in scope). Genre rows aren't draggable in M17 (a genre dropped on the editor would append the whole genre; left out until someone asks).
- AXIDs: the list `library.genres`, each row `library.row.genre.<sanitised first member uri>`.
- The toolbar's Refresh reloads the list and the open genre.

### 2.3 Genre detail (detail column)

```
┌──────────────────────────────────────────────┐
│ Electronic                                    │
│ 403 tracks · 39 albums · 33 artists           │
│ [▶ Play]  [⤮ Shuffle]                         │
│ ┌ Albums │ Artists │ Tracks ┐                 │
│ │ ▣ Album title — Artist         2019         │
│ │ ▣ …                                         │
└──────────────────────────────────────────────┘
```

- A header with the name, the counts line (only non-zero parts), and **Play** / **Shuffle** buttons (`library.genre.play`, `library.genre.shuffle`).
- A segmented picker over **Albums | Artists | Tracks** (`library.genre.kind`). A kind whose count is 0 is left out of the picker (Classical shows Artists and Tracks; Dance shows only Tracks, and then no picker at all, just the list). The default kind is the first non-empty one in that order. The picked kind is remembered per genre for the session, not across launches.
- Each kind is a `PagedList` over `music/<kind>s/library_items {genre: [ids], order_by: "sort_name"}`, with `media_counts` as the total. Rows are the existing row views and behave as everywhere else in the Library:
  - **Albums**: `libraryContainerActions` (double-click plays, context menu Play / Play Next / Add to Queue / Add to Playlist ▸ / Favorite), draggable to the playlist editor; selecting one pushes its tracks, as Favorites does (`NavigationStack` with `library.selectedAlbum`).
  - **Artists**: context menu as in Artists; selecting one switches to the Artists section with that artist selected (as Favorites' artists do).
  - **Tracks**: `TrackListView` rows with `libraryTrackActions(rows:album: nil, …)`: double-click plays the selected track (a row outside an album plays just the selection, `PlayRequest.play(_:in:album:)`), Play Next, Add to Queue, Add to Playlist ▸, Favorite, drag to the editor.
- With no genre selected: `ContentUnavailableView("Select a genre", systemImage: "guitars")`.
- AXID `library.genre.detail`; list rows keep their existing ids (`library.row.album.…`, `library.row.track.…`).

### 2.4 Play and shuffle a genre

- **Play**: `play_media {media: [genre URIs], option: "replace"}`. **Shuffle**: the same with `shuffle: true`. **Play Next** / **Add to Queue** (row menu): `option: "next"` / `"add"`, no shuffle (the server ignores it there).
- The server expands the genre into tracks. How many, and in which order, is unrecorded (§5, risk 2): MA expands a genre the way it expands an artist (its library tracks). If the server refuses a genre URI, Roadie falls back to fetching the tracks itself (§4.3).
- Play goes to the selected output like every other Library play (`PlayerModel.playFromLibrary`), This Mac through Sendspin included; the local-playback gate is unchanged.
- The status notice after a play says what was queued only if the code already does that for albums; nothing new.

### 2.5 Keyboard and accessibility

Return on a selected genre plays it (the list's primary action); ⌥Return shuffles. Space in the detail is untouched. VoiceOver reads a row as "Classical, 649 tracks" and the buttons as "Play Classical", "Shuffle Classical".

---

## 3. Paging and the 99-of-113 gap

`count` said 113 and the first page of 100 returned 99. Candidates, in order of likelihood:

1. **Non-default genres.** `media_type`'s description says it returns "all genres (**including non-defaults**)". So a plain `library_items` call likely skips genres that aren't in the default taxonomy (genres the scanner created from tags), while `count` counts every row. Those can hold music ("Christmas Music" sounds like a tag, not a default genre), so they matter.
2. **Globally excluded genres.** `remove` soft-deletes by default ("exclude globally ... so the scanner will not recreate it"); `count` may still count those rows.
3. **Post-`LIMIT` filtering.** The server reads 100 rows and drops some afterwards, so a short page isn't the last page.

Each needs a different fix (1: query by `media_type`; 2: nothing, they're meant to be hidden; 3: never stop on a short page). The recorder settles it (#0222, `--record-genres`, read-only). It records:

| Fixture | Call |
|---|---|
| `genres-count` | `count` |
| `genres-page` | `library_items {limit: 100, offset: 0, order_by: "sort_name"}` (the call #0220 made) |
| `genres-page-2` | the same with `offset: 100` |
| `genres-page-all` | `{limit: 500, offset: 0}` |
| `genres-page-full` | `{limit: 500, offset: 0, summary: false}` (shows `content_type` and aliases) |
| `genres-hide-empty` | `{limit: 500, hide_empty: true}` |
| `genres-music` | `{limit: 500, content_type: "music"}` |
| `genres-music-hide-empty` | `{limit: 500, content_type: "music", hide_empty: true}` |
| `genres-podcast`, `genres-audiobook` | `{limit: 500, content_type: …}` |
| `genres-media-type-track`, `-album`, `-artist` | `{limit: 500, media_type: …}` |
| `genres-global-exclusions` | `global_exclusions` |
| `genres-scanner-status` | `scanner_status` |
| `genres-media-counts` | `media_counts {genre_ids: <every id seen in any listing above>}` |
| `genre-get` | `get` for the largest genre |
| `genre-tracks`, `genre-albums` | `tracks` / `albums {item_id: <largest>, limit: 5}` |
| `genre-overview` | `overview {item_id: <largest>}` |
| `genre-tracks-filter`, `genre-albums-filter`, `genre-artists-filter`, `genre-playlists-filter` | `music/<kind>/library_items {genre: [<largest>], limit: 5}` |
| `genre-tracks-filter-merged` | `music/tracks/library_items {genre: [<a duplicate pair>], limit: 5}` (the array form) |
| `genres-for-track` | `genres_for_media_item {media_type: "track", media_id: <first track of genre-tracks>}` |

It prints a probe summary to the terminal and to `docs/ma-protocol/genres-probe.txt`: each listing's item count, the ids `count` implies but no listing returned, which listings contain which of those, and per `content_type` how many genres have music. Every list is kept whole (genres are small), except the tracks/albums/artists ones (5).

**The rule until the probe says otherwise** (#0223 adjusts it to the probe's answer and says so in `docs/ma-protocol-notes.md`):

- List with `content_type: "music"` (podcast/audiobook taxonomies out, §6 question 1) and page by **requested** limit: offsets 0, 100, 200, …, stopping on an **empty** page, never on a short one, with a hard cap of 20 pages. Dedupe by `item_id` across pages.
- If the probe shows non-default genres missing from the plain listing (case 1), list with `media_type: "track"`, `"album"` and `"artist"` instead and take the union (three calls, each one page of 500 in practice); `media_type` takes precedence over `hide_empty`, so counts still come from `media_counts`.
- `media_counts` once for every listed id (one call; chunk by 200 ids if the list ever grows).
- A genre's lists page normally through `PagedList` (100 per page, `media_counts` as the total; a short page there ends the list only when `offset + items >= total`).

---

## 4. Architecture

### 4.1 `MusicBackendKit`

```swift
extension BackendCapabilities {
    /// Genres: `genres()`, a genre's albums, artists and tracks (#0223).
    public static let genres = BackendCapabilities(rawValue: 1 << 9)
}

public enum MediaKind { case artist, album, track, playlist, radio, genre }   // + .genre

public struct GenreCounts: Hashable, Sendable { public var tracks, albums, artists, playlists: Int }

/// One row of the Genres list: one genre, or several with the same name (merged).
public struct LibraryGenre: Identifiable, Hashable, Sendable {
    public var id: MediaID              // the first member's (`.genre`, uri)
    public var name: String
    public var sortName: String?
    public var members: [MediaID]       // every genre id the row stands for, in listing order
    public var counts: GenreCounts
}

public enum GenreList {
    /// Drops genres without music, merges equal names, orders by size (§2.2). Pure; tested.
    public static func visible(_ genres: [LibraryGenre]) -> [LibraryGenre]
    /// "649 tracks · 3 artists"
    public static func countsText(_ counts: GenreCounts) -> String
}

extension MusicBackend {
    // Defaults throw .unsupported(.genres).
    func genres() async throws -> [LibraryGenre]                                   // unmerged, with counts
    func albums(inGenre genre: LibraryGenre, page: PageRequest) async throws -> Page<LibraryAlbum>
    func artists(inGenre genre: LibraryGenre, page: PageRequest) async throws -> Page<LibraryArtist>
    func tracks(inGenre genre: LibraryGenre, page: PageRequest) async throws -> Page<LibraryTrack>
    // Play with the server's shuffle (#0225). Default: play, then transport(.setShuffle(true)) when shuffled.
    func play(_ items: [MediaID], on output: OutputDevice.ID, mode: PlayMode, shuffled: Bool) async throws
}

extension PlayRequest {
    public var shuffled: Bool          // default false
    public static func play(genre: LibraryGenre) -> PlayRequest       // members, .replace()
    public static func shuffle(genre: LibraryGenre) -> PlayRequest    // members, .replace(), shuffled
    public static func next(genre:), append(genre:)
}
```

`MediaKind.genre` touches every exhaustive switch over `MediaKind`: `MAMediaKind` (gains `.genre`; `plural` gives `genres`), `FavoriteKind.init?(_:)` (nil), `FolderBackend.play` (`.unsupported(.genres)`), `StubMusicBackend`, `ScriptedMusicAssistant.expand`, `LibraryBrowserModel`'s switches, `AXID`/`DiscoverView` symbol tables. The compiler lists them.

### 4.2 `MusicAssistantKit`

- `MAGenre: Codable` (`item_id`, `provider`, `name`, `sort_name`, `uri`, `favorite`, `content_type?`, `genre_alias_count?`), with the lenient list decode the other items use. `MAGenreCounts` decodes `media_counts`' object with whatever keys the recording shows (expected `track`, `album`, `artist`, `playlist`; unknown keys ignored, missing ones 0).
- `MARequest.genres(limit:offset:contentType:mediaType:)`, `.genreMediaCounts(ids:)`, `.libraryItems(_ kind:, limit:, offset:, genres: [Int])` (the existing builder gains an optional `genres`), and `.playMedia(…, shuffle: Bool? = nil)` (sends `shuffle` only when non-nil).
- `MusicAssistantBackend+Genres.swift`: `genres()` per §3, `albums/artists/tracks(inGenre:page:)` via `library_items {genre: members' item ids as Int}` with the total from the genre's counts, and `play(_:on:mode:shuffled:)` sending `shuffle: true` (only for `.replace`). `capabilities` gains `.genres`.
- `LibraryGenre(ma:counts:)` in `MAMapping.swift`.

### 4.3 Play fallback

If `play_media` answers an error for a genre URI (the schema says it takes one; unverified), the backend expands the genre itself: `music/genres/tracks {item_id, limit: 0}` per member (or `order_by: "random"` when shuffled), capped at 2,000 tracks (the remote queue cap, #0132), then plays the track URIs. #0225 decides from the by-hand check whether the fallback is needed; it is written and unit-tested either way, behind "the server refused the genre URI".

### 4.4 The folder backend

**No genres on the folder library in M17.** `FolderIndex` doesn't read genre tags today (`FolderTrack` has no genre field), and adding one means an index version bump, a full reindex for every user, and tag reading for MP3 (ID3 `TCON`, with its `(17)` numeric form), M4A (`©gen`/`gnre`) and FLAC (Vorbis `GENRE`). It's a self-contained follow-up worth its own issue once Music Assistant genres have landed: the protocol above is backend-neutral (`genres()`, the three lists, `PlayRequest.play(genre:)`), so a later `FolderBackend` only implements those and sets `.genres`. Until then the folder backend lacks the capability and the Library shows no Genres section; `GenresUITests.folderLibraryHasNoGenres` pins that.

### 4.5 `LibraryBrowser`

`GenresModel` (`@MainActor @Observable`, owned by `LibraryBrowserModel` like `FavoritesModel`):

- `phase: LoadState<[LibraryGenre]>` (already passed through `GenreList.visible`), `load()`, `reload()`, generation-guarded like `FavoritesModel.loadCounts`.
- `selectedGenreID: MediaID?`; `selectedKind: GenreKind` (`.albums`, `.artists`, `.tracks`); `availableKinds(for:)`.
- `albums`, `artists`, `tracks`: `PagedList`s, reloaded when the selection changes, loaded lazily per kind.
- `onFailure` reports through `LibraryBrowserModel.reportFailure` like the other lists.
- `LibraryBrowserModel.loadSection(reloading:)` gains `case .genres`; `refresh()` reloads the list and the open genre's current kind.

### 4.6 Stub and scripted server

- `StubMusicBackend`/`StubLibrary`: a few genres with counts (one duplicate name pair, one empty genre), lists filtered from the stub's own albums/artists/tracks, and `.genres` in its capabilities, so `LibraryBrowserTests` can drive `GenresModel` without Music Assistant.
- `ScriptedMusicAssistant`: answers `music/genres/library_items` (honouring `content_type`, `media_type`, `hide_empty`, `limit`/`offset` from the recorded listings), `count`, `media_counts` (the recorded object, filtered to the requested ids), and `music/<kind>s/library_items {genre}` from the recorded `genre-*-filter` fixtures for the recorded genre id (any other id: an empty array). `play_media` with a `library://genre/<id>` URI expands to the recorded `genre-tracks` (SYNTHETIC expansion, labelled so: the real expansion is unrecorded) and records `shuffle=true` in `maRequests` when sent.

### 4.7 Tests

Fast tests with the recorded fixtures (`ModelDecodingTests` decode each genre fixture; `MAFixtureTests` knows the new cases), `GenreList` pure tests, backend tests over `FixtureScript`/`ScriptedMusicAssistant`, `GenresModel` tests over the stub, recorder tests without a server (`scripts/tests/test_record_genres.py`). One new UI class, `GenresUITests`, over the scripted server (`libraryIdle`) plus one folder-library test. Inventory rows in `docs/design/test-automation.md` §5.7, added by #0224 and #0225.

---

## 5. Risks

1. **The 99-of-113 gap hides music.** If plain `library_items` skips non-default genres that have tracks, the list is missing rows with no error. Mitigation: #0222's probe before any decoding work; #0223's listing follows its answer; a unit test pins "a genre only `media_type: track` returns is listed".
2. **What `play_media` does with a genre is unrecorded** (playing is a write; the recorder doesn't send it). It may play every track, a capped random sample, or refuse. Mitigation: the fallback in §4.3, and #0225's by-hand step plays Classical (649 tracks) and reads the queue length.
3. **`media_counts`' shape is unrecorded.** The key names and whether ids are keyed as strings are known only after #0222. Decoding is lenient and the scripted server serves the recording, so a shape change shows up as a decode test failure, not a crash.
4. **Integer vs string ids.** `library_items {genre}` wants integers, `media_counts` strings. A genre id that isn't numeric (a provider genre) can't be filtered; such genres are skipped with a log line (none expected: every genre on the user's server has `provider: "library"`).
5. **Counts vs lists can disagree.** `media_counts` may count an album mapped through its tracks while `albums/library_items {genre}` only returns albums mapped directly (or the reverse). The probe records both for the largest genre; when they disagree, the picker hides a kind only when its *list* is empty, and the count line keeps the server's number.
6. **The scanner runs in the background.** Counts change while the user browses (`scanner_status`). Refresh picks it up; no live updates in M17 (genre events aren't recorded, #0076).
7. **`MediaKind.genre` is a wide change.** Every switch over `MediaKind` changes, including `MediaIDTransfer` decoding on the pasteboard (a `genre:` id from a newer build dropped into an older one). Genre rows aren't draggable in M17, so no genre id reaches the pasteboard.

---

## 6. Open questions for the user (defaults in the plans)

1. **Podcast and audiobook genres.** Default: hidden, even when they have content (none do today). Roadie doesn't play podcasts or audiobooks at all, so a podcast genre would open to nothing playable. The list asks for `content_type: "music"`; if the probe shows that filter doesn't work, Roadie drops genres whose full item says `content_type` `podcast`/`audiobook`.
2. **Playlists in a genre.** Classical has 2 playlists. Default: not shown (the accepted scope is albums, artists and tracks). Adding a Playlists tab is one more `library_items {genre}` list if wanted.
3. **Order.** Default: by size (track count), no alphabetical toggle. Say if you want A–Z, or a toggle.
4. **Genres on the folder library.** Default: not in M17 (§4.4); a follow-up issue if you want it.
5. **What Play does on a huge genre.** Default: whatever the server does with `play_media` (risk 2); Roadie caps only its own fallback, at 2,000 tracks.

---

## 7. Children and their order

| Issue | Title | Blocked by | Tier |
|---|---|---|---|
| [#0221](../../issues/0221.md) | A playlist the user created in Music Assistant is listed under "Built-in" and can't be renamed or deleted | #0206 | ui |
| [#0222](../../issues/0222.md) | Genre responses from Music Assistant are unrecorded, and nobody knows why the genre list is 14 short | — | fast |
| [#0223](../../issues/0223.md) | The Music Assistant backend can't list genres or a genre's albums, artists and tracks | #0222 | fast |
| [#0224](../../issues/0224.md) | The Library has no Genres section | #0223 | ui |
| [#0225](../../issues/0225.md) | A genre can't be opened to its albums, artists and tracks, or played or shuffled as a whole | #0224 | ui |

Order: #0221 any time after M16 (independent of the genre chain). #0222 first in the chain: its probe decides the listing rule in #0223. Then #0223 (no UI), #0224 (the list), #0225 (detail and play). #0224 and #0225 add `GenresUITests`, which uses the `RoadieUIApp` Library helpers from #0205/#0206 when they exist; it is a class of its own so it doesn't collide with #0206's `MusicAssistantUITests`. Milestone end: `scripts/verify.sh --head --full --ui --ui-skins all --coverage`.

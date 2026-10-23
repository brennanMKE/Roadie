# Music Assistant protocol notes (recorded)

Real message shapes from a running server, resolving every **VERIFY** marker in [music-assistant-integration.md](music-assistant-integration.md). Issue #0060.

- **Server:** Music Assistant `server_version` 2.10.6, `schema_version` 65, `min_supported_schema_version` 28, running as the Home Assistant add-on. Recorded 2026-10-14 (recorder run `20261014-153328`).
- **Library on that server:** 475 artists, 449 albums, 2168 tracks, 8 playlists, all from a `filesystem_smb` provider plus the `builtin` provider (random-track playlists). **No Plex provider is configured**, so Plex-specific fields (Plex ids and image URLs in `provider_mappings`) were not recorded; #0074 dropped direct Plex support anyway.
- **Players on that server:** nine, of which three were available and none was playing, so `current_media` is `null` and `player-queue-items` is empty. Nothing was played, paused or changed: the recorder sends only the allowlisted read commands in `scripts/record-ma-fixtures.py` (`ALLOWED`).
- **Repeat the recording:** `/usr/bin/python3 -I scripts/record-ma-fixtures.py` (needs `.env`, network only, no audio), then `/usr/bin/python3 -I scripts/record-ma-fixtures.py --check` for the secret gate. `--out DIR` redirects every output; `--events-seconds N` sets the event window. `--check-live` (#0061) is a read-only drift check against the real server: it prints one `live: <check> ok|FAIL` line per check and writes nothing.
- **Fixtures:** `Packages/PlayerKit/Sources/MusicAssistantKitStub/Fixtures/*.json`. A call fixture is `{"command", "args", "frames": [verbatim server frames]}`; the handshake is `{"frames": [...]}`; events are `{"events": [{"after_ms", "frame"}], ...}`. Values are scrubbed (server id, user, hosts become `0123...`, `user`, `ma.example`); keys are untouched. `message_id`s are as sent.
- **Command list:** `docs/ma-protocol/commands.json` (310 commands, verbatim) and `docs/ma-protocol/openapi.json` (host scrubbed). Both come from `GET /api-docs/commands.json` and `/api-docs/openapi.json`; `/api-docs` itself is an HTML page.

## 1. Server-info handshake

The first frame after the WebSocket upgrade is **bare** (not wrapped, no `message_id`) and has the twelve fields of `GET /info` (which needs no auth): `server_id`, `server_version`, `schema_version`, `min_supported_schema_version`, `base_url`, `homeassistant_addon`, `onboard_done`, `name`, `status`, `internal_url`, `external_url`, `has_remote_access`. See `server-info.json`. The `info` command after auth returns the same twelve fields (`info-ws.json`).

Verdict: the doc's six expected fields are all there plus six more. Use `server_id` for the identity check (`base_url` and `internal_url` are LAN addresses and can differ from the host the user typed).

## 2. `auth`

Request: `{"message_id": "1", "command": "auth", "args": {"token": "<long-lived token>"}}`. Result frame: `{"message_id": "1", "result": {"authenticated": true, "user": {"user_id", "username", "role", "enabled", "created_at", "display_name", "avatar_url", "preferences", "provider_filter", "player_filter"}}, "partial": false}` (`auth-ok.json`). `auth/me` returns the same user object (`auth-me.json`).

A bad token yields an ordinary error frame and the socket stays open: `{"message_id": "1", "error_code": 23, "details": "The access token is invalid or has expired."}` (`error-auth.json`).

Any other command before auth is also an error frame, not a socket close: `{"message_id": "2", "error_code": 20, "details": "Authentication is required."}` (`error-unauthenticated.json`). Only `time` works unauthenticated (`time.json`).

Verdict: send `auth` as the first command; treat `error_code` 23 as "token rejected" and 20 as "not authenticated". Check `server_id` against the one stored at sign-in before sending the token (#0063).

## 3. Envelope

- **Success:** `{"message_id": "<echo>", "result": <value>, "partial": false}`. `partial` is **always present** on results.
- **Null result:** `"result": null` with `"partial": false` (`error-unknown-player.json`: `players/get` for an unknown id is a success with a null result, **not** an error).
- **Error:** `{"message_id": "<echo>", "error_code": <int>, "details": "<string>"}`. `error_code` is an integer (12 `Invalid or unsupported command.` in `error-unknown-command.json`, 20 and 23 above) and `details` is a string. There is no `result` or `partial` key.
- **Streamed (`partial`):** `music/playlists/playlist_tracks` sends several frames with the same `message_id`: `{"result": [chunk of up to 500 tracks], "partial": true}` followed by a final `{"result": [], "partial": false}` (`playlist-tracks.json`; the fixture keeps the first five items of the first chunk and records the real count in `original_item_counts`). **Each partial frame is a chunk, not cumulative; concatenate the `result` arrays, and the frame with `partial: false` ends the call** (its result was empty here and may carry the remainder in general).
- **Event:** see section 8.

Verdict: the doc was right that errors carry `error_code` and `details` and that large results stream with `partial`; it was wrong that there is a separate success flag, and `object_id` on events is not confirmed (no event captured).

## 4. Heartbeat

The server sent one WebSocket **ping** control frame about 25 s after connect (in a 30 s idle window), and the client must answer with a pong (the recorder does). No application-level heartbeat message exists. The doc's "55 s heartbeat" is the Python client's own setting.

Verdict for #0061: `URLSessionWebSocketTask` answers server pings automatically; send a client ping every 20 to 30 s to detect a dead link and reconnect on failure.

## 5. Players and transport

`players/all` (`players-all.json`) returns an array of `Player`. Keys that matter for `OutputDevice`: `player_id`, `provider` (`airplay`, `universal_player`, `sendspin`, ...), `type` (`player` for all nine here; `group`/`stereo_pair` exist in the schema), `name`, `display_name`, `available`, `enabled`, `hide_in_ui`, `playback_state` (`idle|paused|playing`), `powered`, `volume_level`, `volume_muted`, `group_members`, `synced_to`, `active_group`, `supported_features` (strings such as `play_media`, `pause`, `volume_set`, `set_members`), `current_media`. Also `needs_setup`, `power_control`, `volume_control`, `mute_control`, `output_protocols`. By default `players/all` already includes unavailable players (`players-all-unavailable.json` with `return_unavailable` and `return_disabled` has the same nine); filter on `available`, `enabled` and `hide_in_ui` client-side. No grouped player existed, so `group_members`, `synced_to` and `active_group` were empty or null (`get_active_queue` for a grouped player is unrecorded).

`players/get` takes `player_id` (and optional `raise_unavailable`); an unknown id returns `result: null`.

**`queue_id` equals `player_id` for every player here** (`player-queues-all.json` has the same nine ids). `PlayerQueue` fields: `queue_id`, `active`, `display_name`, `available`, `items` (an **integer count**, not an array), `shuffle_enabled`, `repeat_mode`, `current_index`, `elapsed_time`, `elapsed_time_last_updated`, `state`, `current_item`, `next_item`, `crossfade_enabled`, `autoplay_enabled`, `dont_stop_the_music_enabled`, and others. Queue contents come from `player_queues/items` (`queue_id`, `limit`, `offset`).

Transport arguments (from `commands.json`; **none was sent**). Scopes: `players.control`, `queues.control`.

| Command | Args |
|---|---|
| `players/cmd/play`, `pause`, `play_pause`, `stop`, `next`, `previous` | `player_id` |
| `players/cmd/seek` | `player_id`, `position` (integer seconds) |
| `players/cmd/volume_set` | `player_id`, `volume_level` (integer, 0..100) |
| `players/cmd/volume_mute` | `player_id`, `muted` (bool) |
| `players/cmd/shuffle` | `player_id`, `shuffle_enabled`, optional `source_id` |
| `players/cmd/repeat` | `player_id`, `repeat_mode` (`off|one|all`), optional `source_id` |
| `player_queues/play`, `pause`, `play_pause`, `stop`, `next`, `previous`, `resume` | `queue_id` |
| `player_queues/seek` | `queue_id`, `position` (integer, optional) |
| `player_queues/shuffle` / `repeat` | `queue_id`, `shuffle_enabled` / `repeat_mode` |
| `player_queues/play_media` | `queue_id`, `media` (URI, item, or array of either), optional `option` (`play|replace|next|replace_next|add`), `radio_mode`, `start_item`, `sort_by`, `start_from_beginning`, `shuffle` |
| `player_queues/get`, `get_active_queue`, `items` | `queue_id`; `player_id`; `queue_id` + optional `limit`, `offset` |

## 6. Search

One call: `music/search` with `search_query` (required), `media_types`, `limit` (per type), `providers`, `user`; `library_only` is listed but deprecated, so use `providers: ["library"]` (`search.json`). The result is `{"artists": [], "albums": [], "genres": [], "tracks": [], "playlists": [], "radio": [], "audiobooks": [], "podcasts": [], "sound_effects": []}` (always all nine keys, arrays possibly empty). The recorded query returned one track and no other media; items carry `library://` URIs. The `providers: ["library"]` argument was accepted without error.

## 7. Listings and paging

`music/{artists,albums,tracks,playlists}/library_items` take `limit`, `offset`, `order_by` (`sort_name` was accepted), `search`, `favorite`, `provider`, `genre`, `summary` and more (see `commands.json`). They return a **bare array with no total** (`result` is the array). Totals come from `music/{artists,albums,tracks,playlists}/count`, which return a **bare integer** (`artists-count.json`: `result: 475`). The count command accepts the same filters as the listing; the recorded artist page used `album_artists_only: true` while the count did not, so the recorded "last page" at `offset = count - 1` was empty (`artists-last-page.json`): pass identical filters to both calls. Albums and tracks last pages returned one item (`albums-last-page.json`, `tracks-last-page.json`).

The stray `kwargs` parameter listed as required in `commands.json` was never sent and the server did not object: ignore it.

`summary: true` (the default) versus `summary: false` (`*-page-full.json`) differ little for this library: the slim item drops `date_added` and `position` and keeps `available`; tracks additionally gain `audio_metadata` when not slim. `provider_mappings`, `artists`, `album`, `duration`, `track_number`, `disc_number` are present in both. Images are in `metadata.images` (null for items without art).

URIs: `library://artist/<id>`, `library://album/<id>`, `library://track/<id>`, `library://playlist/<id>`; `provider` is `"library"` and `item_id` is the library id. `LibraryTrack` fields: `item_id`, `name`, `uri`, `duration` (seconds, integer), `track_number`, `disc_number`, `artists[]` (`item_id`, `name`, `uri`), `album` (`item_id`, `name`, `uri`, `year`), `last_played`, `favorite`, `provider_mappings[].audio_format` (`content_type`, `sample_rate`, `bit_depth`, `channels`, `bit_rate`).

Children: `music/artists/artist_albums`, `music/albums/album_tracks`, `music/playlists/playlist_tracks` all take `item_id` and `provider_instance_id_or_domain` (`"library"` works); `music/item_by_uri` takes `uri`; `music/albums/get` takes `item_id` + `provider_instance_id_or_domain`. `providers` with `provider_type: "music"` lists `{type, domain, name, instance_id, supported_features, available, is_streaming_provider, lookup_key}` (`providers.json`).

## 8. Events

There is **no subscribe command**; authenticated sockets receive pushed events. In the committed run's 30 s window (and a 60 s trial), **no event frame was captured** (nothing was playing and the recorder cannot cause playback), so the event envelope's `object_id` field and the shapes of `player_updated` and `queue_time_updated` are **unverified**. The API landing page documents the frame as `{"event": "<name>", "data": ...}` and lists these names: `player_added/updated/removed`, `player_config_updated`, `queue_added/updated/items_updated/time_updated`, `media_item_added/updated/deleted/played`, `providers_updated`, `tasks_updated`, `music_sync_completed`, `application_shutdown`. None of the four host transcripts (three implementation runs and the review re-run, 30 to 60 s windows each) contains a pushed frame without a `message_id`, so even the bare envelope is taken from the API page, not from a recording; #0061 should decode events leniently (`event` string, optional `object_id`, `data` kept as raw JSON). Re-record `events.json` while pausing and resuming an already playing speaker from the MA web UI (the plan's optional hand action) to settle this; tracked as #0076.

The `time` command returns server UTC seconds as a float (`time.json`); `elapsed_time` plus `elapsed_time_last_updated` on `Player` and `PlayerQueue` are the basis for extrapolating position (#0064, #0069); correct for clock skew with `time`.

## 9. Artwork

`MediaItemImage` is `{type, path, provider, remotely_accessible, proxy_id}` (`artwork-probe.json`, `image_fields`). `Player.current_media.image_url` is an absolute URL (it uses the server's own base URL, so rewrite the host to the configured one): `/imageproxy/<proxy_id>?size=512&fmt=jpg`.

Probe results (`artwork-probe.json`), each with and without an Authorization header:

- `/imageproxy/<proxy_id>?size=512&fmt=jpg` (the server's own URL): **200 image/jpeg** with and without auth.
- `/imageproxy/<proxy_id>?size=256` and `?size=256&fmt=jpg`: **200 image/jpeg**, with and without auth.
- `/imageproxy/<proxy_id>?size=200`: **400**, `Unsupported size 200: must be one of 0, 80, 160, 256, 512, 1024 (0 = original size).`
- `/imageproxy?path=<path>&provider=<provider>&size=200` (older form): **400**.

Verdict: the image proxy is keyed by `proxy_id`, needs no authorization, and accepts only the sizes 0, 80, 160, 256, 512, 1024. Ask for `size=256` (not `ArtworkCache.thumbnailPixels` 200) or round up to the next allowed size. Suggest `ArtworkRef.rawValue = proxy_id`; build `<base>/imageproxy/<proxy_id>?size=256`. Items without a `proxy_id` have no art.

## 10. Discovery

`dns-sd -B _music-assistant._tcp` found **nothing** within 5 s. `dns-sd -B _services._dns-sd._udp` listed service types on the network including `_sendspin-server._tcp` but no `_music-assistant._tcp` (`docs/ma-protocol/dns-sd.txt`).

Verdict: the Home Assistant add-on does not advertise `_music-assistant._tcp`. Keep the manual host:port field as the primary path (#0063). `_sendspin-server._tcp` is advertised (the Sendspin endpoint on port 8927), which is not the API port. Only add a service type to `NSBonjourServices` if discovery is built on one.

## 11. Mapping to `MusicBackend` (recommendations for #0061 and #0064)

- `Page`: array from `library_items` plus `*/count`; `Page.make(items:request:total:)` can pass the count or `nil`. Use the same filters on the listing and its count.
- `PlayMode.replace(startIndex:)`: `player_queues/play_media` with `option: "replace"` and `start_item: <track uri>`; `.append`: `option: "add"`; "play next": `option: "next"`.
- `search`: one `music/search` call with `providers: ["library"]`.
- `OutputDevice` from `Player`: use `player_id`, `display_name`, `available`, `enabled` and `hide_in_ui`; group state from `group_members` and `synced_to` (unverified on this server).
- `NowPlaying` from `PlayerQueue` (`current_item`, `elapsed_time`, `state`) and `Player.current_media`.
- `disconnect()` sends a close frame (code 1000; the server accepted it).

## 12. Differences from `music-assistant-integration.md`

- `/api-docs` is an HTML page; the command list is `GET /api-docs/commands.json` and the schemas are `GET /api-docs/openapi.json`. Neither needs auth.
- Server-info has twelve fields, not six.
- `info` as a command requires auth (the `GET /info` HTTP endpoint does not); `time` needs no auth.
- No subscribe or `start_listening` command; events are pushed after `auth`.
- The envelope always carries `partial` on results; errors have an integer `error_code` and a string `details`; unknown ids can return `null` rather than an error.
- Library listings return a bare array and have a `summary` flag (default true); totals come from `*/count`.
- `music/search` has `providers` (and a deprecated `library_only`).
- `playlist_tracks` takes `provider_instance_id_or_domain` (the doc's `provider_instance_or_domain` is wrong).
- `PlayerQueue.items` is a count; queue contents need `player_queues/items`.
- The image proxy needs a `proxy_id` URL with an allowed size and no auth; `size=200` fails.
- The server pings the client (about every 25 s); the "55 s heartbeat" is the Python client's own.
- The add-on is not discoverable as `_music-assistant._tcp`.

## 13. Per-track audio over HTTP (#0089)

Probed read-only from the host on 2026-10-19 with `scripts/record-ma-fixtures.py --probe-audio --write` (scrubbed result: `ma-protocol/track-audio-probe.json`). Server 2.10.6, schema 65.

- **No full-track endpoint for a client that is not a player.** The only per-track audio command is `music/tracks/preview`; the command list has nothing else matching `stream`, `preview`, `builtin_player`, `web_player` or `register` except `dashboard/register|unregister` and `sendspin/pair_web_player`.
- **`music/tracks/preview`** (scope `library.read`) returns a **relative** URL, `/preview` with a single `token` query parameter, on the API webserver (8095). Both the `library` id and the provider mapping id work. The token is single-purpose and short-lived: the same URL answers 404 65 s later (upstream `PREVIEW_TOKEN_TTL = 60`).
- **`GET /preview`** answers `200 audio/aac`, chunked, no `Content-Length`, no `Accept-Ranges`, with or without `Authorization`. Upstream it is a 30 s ffmpeg ADTS sample (`-t 30`). On this server (tracks from `filesystem_smb`, MP3) it returned an empty body for every track tried, so even the preview is unusable here.
- **The stream server (8097)** has no `/info` route (404) and serves full tracks only on `/flow|single/{session}/{queue}/{item}/{player}`, to a registered player in a live queue session.

Verdict: full audio on This Mac needs the Mac to be a player, which on 2.10.6 means Sendspin (#0066). The HTTP path is closed.

## 14. Playlists, favorites, Discover and queue captures (#0133)

Pending: the recorder supports these captures (playlists design `docs/design/playlists.md` §1.5), but no recording has landed yet. Until it does, `MAFixture.isRecorded` is false for the new cases and tests use synthetic routes.

The user runs both on the host (needs `.env`; agents never contact the server):

1. **Reads (default run, as before):** `/usr/bin/python3 -I scripts/record-ma-fixtures.py && /usr/bin/python3 -I scripts/record-ma-fixtures.py --check`
   Adds `playlist-get`, `playlists-favorites-page`, `tracks-favorites-page`, `recommendations`, one `recommendations-items-<item_id>` per row (3 items kept, real counts in `original_item_counts`), `recently-played-items`, `recently-added-tracks`, `radios-count`, `radios-page`, `playlist-export` (first editable playlist; skipped when none), and `player-queue-items-loaded` (first queue with items, 5 kept; start something playing first to get it).
2. **Writes (opt-in):** `/usr/bin/python3 -I scripts/record-ma-fixtures.py --record-playlist-writes && /usr/bin/python3 -I scripts/record-ma-fixtures.py --check`
   Uses its own allowlist (`ALLOWED_WRITES`). Creates `Roadie fixture <run-id>`, adds the first two library tracks, lists, removes position 1, lists, renames with `overwrite: true`, probes `move_playlist_track` (expected `error-unknown-command-move` on 2.10.6), adds and removes the first track as a favorite (skipped if it already was one), and deletes the playlist in a `finally` even if a step failed. Writes `playlist-create`, `playlist-add-tracks`, `playlist-tracks-after-add`, `playlist-remove-tracks`, `playlist-tracks-after-remove`, `playlist-update`, `error-unknown-command-move`, `favorite-add`, `favorite-remove`, `playlist-delete` and the pushed frames in `events-playlists.json`. Nothing else is modified. Cleanup runs in a `finally`, even after a failed step or Ctrl-C: it first removes the favorite again if the run added it and the in-run removal did not succeed, then deletes the playlist. An error frame, no reply before the timeout, or an exception (including a second Ctrl-C) on either step prints `CLEANUP FAILED` naming what to fix by hand in the Music Assistant UI: `un-favorite the track '<track name>'` or `delete the playlist named '<name>'`. If `create_playlist` was sent but its result was unknown (timeout, unexpected shape, interrupted), it prints `CLEANUP FAILED: the playlist named '<name>' may exist`; check for it and delete it. An interrupt is reported first and then still stops the script. The cleanup logic is tested without a server: `/usr/bin/python3 -I -B scripts/tests/test_record_writes_cleanup.py`.

A later default run keeps the writes run's files. `--check` also verifies that every fixture parses and that each writes fixture carries an allowlisted command and a playlist id.

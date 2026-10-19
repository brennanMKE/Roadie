# Music Assistant Backend: Setup and Integration Brief

Handoff doc for adding Music Assistant (MA) as the default music backend in the Winamp-skin macOS music player, with Plex kept as an alternate backend selectable in Settings.

Researched 2026-10-13 against Music Assistant 2.10.6 and Home Assistant 2026.10.1. Anything marked **VERIFY** was not confirmed from primary docs and must be checked against the running server's `/api-docs` before coding against it.

---

## 1. What Music Assistant is (and why talk to it directly)

- MA is a standalone server (Python) that merges music sources (Plex, local files, Jellyfin, Subsonic, streaming services) into one library and streams to players (AirPlay incl. HomePod, Chromecast, Sonos, DLNA, Sendspin, etc.).
- The Home Assistant `music_assistant` integration is a thin layer on top: it exposes MA players as HA `media_player` entities plus six actions (`get_library`, `get_queue`, `play_announcement`, `play_media`, `search`, `transfer_queue`). It requires MA server 2.4+.
- **Decision: the app talks to MA's own WebSocket API directly, not through Home Assistant.** HA adds a hop and exposes a much narrower surface (entities + 6 actions). The MA API is what MA's own web UI uses and covers library browse, search, queues, players, artwork and config. HA stays optional for automations.

## 2. Server installation (home network)

### Hard requirements
- 64-bit OS, min 2 GB RAM (4 GB+ if the box does anything else). Raspberry Pi 4 or newer is fine.
- **MA must be on the same layer 2 network as the speakers, no VLANs between.** Discovery uses mDNS/uPnP multicast. This is the #1 cause of failures.
- Docker installs must use `network_mode: host` (or macvlan). AirPlay opens random TCP/UDP ports, so firewalled/port-restricted setups are unsupported.

### Where to run it
Only two installs are supported by the MA team: the Home Assistant App (add-on) on HAOS (bare metal or VM), or a plain standalone Docker container. Not Kubernetes.

| Option | Verdict |
|---|---|
| HAOS on a Pi 4/5, MA as HA App | Easiest and fully supported. Gets HA too. |
| HAOS VM on a Mac mini (UTM, **bridged** networking) | Supported (VM is fine). VM must get its own LAN IP. |
| Docker on a Linux Pi from the fleet | Supported. Use the compose file below. |
| Docker Desktop on macOS | **Avoid.** Docker Desktop runs containers in a Linux VM; host networking is an opt-in feature from 4.34 and does not give the container real L2 multicast on the LAN. Not a supported MA install; HomePod discovery is very likely to fail. |

Run MA on a **different host than Plex Media Server** if you ever enable the Plex Connect plugin: both bind GDM discovery port 32412 and collide. The Plex *music source* itself works fine across hosts.

### Docker compose (Linux host)
```yaml
services:
  music-assistant-server:
    image: ghcr.io/music-assistant/server:latest   # pin a release tag in practice
    container_name: music-assistant-server
    restart: unless-stopped
    network_mode: host
    volumes:
      - ${HOME}/docker/music-assistant-server/data:/data/
      # optional local music, read-only:
      # - /path/to/music:/media:ro
    environment:
      - LOG_LEVEL=info
```
Do not switch stable/beta by changing the tag on an existing data volume.

### HA App route
Settings > Apps (add-on store) > add repo `https://github.com/music-assistant/home-assistant-addon` > install Music Assistant. Then optionally add the HA integration: Settings > Devices & services > Add Integration > Music Assistant (usually auto-discovered).

### Ports
| Port | Purpose |
|---|---|
| 8095/tcp | Web UI, WebSocket API (`/ws`), JSON-RPC over HTTP (`/api`), generated API docs (`/api-docs`) |
| 8097/tcp | Audio stream server (players pull from here; next free port if taken) |
| 8927/tcp | Sendspin endpoint for third-party players: `ws://<ma-ip>:8927/sendspin` |
| 8094 | Internal webserver used by the HA integration when MA runs as an HA App |

The `/sendspin` path on 8095 is reserved for the built-in web player and rejects other clients. Use 8927.

## 3. First-run configuration checklist

1. Open `http://<ma-ip>:8095`, complete first-run auth (create admin user).
2. **Add Plex as a music source:** Settings > Music Sources > Plex.
   - "Use Plex GDM to discover local servers" should fill IP/port; otherwise enter Mac mini IP and `32400`.
   - Auth: "Authenticate on MYPLEX.TV", or allowlist the MA host IP in Plex (Settings > Network > "List of IP addresses and networks that are allowed without auth") and use "Authenticate Locally".
   - One provider instance per Plex library (add the provider again for each library/account).
   - Supports artists, albums, tracks, playlists; up to FLAC 192k/24; no lyrics.
3. **AirPlay / HomePods:** AirPlay provider is added automatically. HomePods/AirPlay 2 devices may show a Setup button; pair from the player settings.
   - In the Home app's home settings for AirPlay speaker & TV access, select **everyone on the same network**, not only people in this home, or HomePods play silence. (Wording per MA docs; exact Home app menu labels not verified.)
   - Output is 44.1 kHz/16-bit lossless (optionally ALAC). Stereo pairs configurable in player settings.
   - **MA cannot AirPlay to a Mac** (macOS dropped RAOP). The Mac must be a Sendspin player to play locally (see 5.2).
4. **Create a long-lived token for the app:** Settings > Profile > Long-lived access tokens. Consider a dedicated non-admin MA user for the app (some commands, e.g. `music/sync`, need admin).
5. Wait for first library sync (spinner beside the source in Settings).
6. Browse `http://<ma-ip>:8095/api-docs` and save the command list; it is generated from the running server and is the source of truth for section 4.

## 4. MA API reference (for the Swift client)

### Transport
- **WebSocket:** `ws://<host>:8095/ws` (the official Python client derives it as base URL + `/ws`). Persistent connection; use for everything plus live events.
- **HTTP JSON-RPC:** `POST http://<host>:8095/api` with header `Authorization: Bearer <token>`. Same command/args shape. Handy for testing with curl.

### Request shape
```json
{ "message_id": "42", "command": "music/albums/album_tracks",
  "args": { "item_id": "1", "provider_instance_id_or_domain": "library", "in_library_only": true } }
```
`message_id` is any string; it is echoed back for correlation.

### Connection handshake (recorded in #0060; see [ma-protocol-notes.md](ma-protocol-notes.md))
1. On connect the server immediately sends a bare **server info** message with twelve fields (`server_id`, `server_version`, `schema_version`, `min_supported_schema_version`, `base_url`, `homeassistant_addon`, `onboard_done`, `name`, `status`, `internal_url`, `external_url`, `has_remote_access`). `GET /info` returns the same without auth.
2. Schema version 28+ requires auth: send `{"message_id":"1","command":"auth","args":{"token":"<token>"}}` first. A bad token is error 23 and any other command before auth is error 20; the socket stays open either way.
3. Responses: success is `{"message_id", "result", "partial"}` (`partial` is always present; large results stream as several chunks with the same id, ended by `partial: false`); errors are `{"message_id", "error_code", "details"}`. Server-pushed events are `{"event", "data"}` per the API page; `object_id` is unconfirmed until #0076.
4. Keep alive: the server pings about every 25 s and `URLSessionWebSocketTask` answers; the client pings on its own to detect a dead link. The "55 s heartbeat" is the Python client's setting.

The client built on this is `MusicAssistantKit` (#0061). `scripts/record-ma-fixtures.py --check-live` re-verifies the shapes against a real server, read-only.

### Commands confirmed in MA docs
| Command | Args |
|---|---|
| `music/albums/album_tracks` | `item_id`, `provider_instance_id_or_domain`, `in_library_only` |
| `music/item_by_uri` | `uri` |
| `music/recently_played_items` | `limit?`, `media_types?` |
| `music/in_progress_items` | `limit?` |
| `music/favorites/add_item` | `item` (URI or share URL) |
| `music/sync` | `media_types?`, `providers?` (admin token) |
| `music/playlists/playlist_tracks` | `item_id`, `provider_instance_id_or_domain`, `force_refresh?` |
| `player_queues/all` | none |
| `player_queues/items` | `queue_id`, `limit` (keep <= 500), `offset` |
| `player_queues/play_media` | `queue_id`, `media` (URI), `start_item?` |
| `config/players/get` / `config/players/save` | `player_id`, `values` |

Recorded in the notes: `players/all`, the `players/cmd/*` transport commands, `music/search` (with `providers: ["library"]`), `music/{artists,albums,tracks,playlists}/library_items` plus `*/count`. There is no `start_listening` or subscribe command; events are pushed after `auth`.

### Identifiers
- URIs look like `library://album/20`, `library://artist/1`, `plex://…`, `spotify://track/…`. Prefer `library://` URIs so items stay stable across providers.
- `queue_id` equals `player_id` unless the player is in a group.
- Artwork: items carry `metadata.images[].proxy_id`; fetch `/imageproxy/<proxy_id>?size=<0|80|160|256|512|1024>` with no credentials (recorded in the notes).

### Discovery
- The Home Assistant add-on does not advertise `_music-assistant._tcp` (checked in #0060); there is no discovery; Settings › Music Assistant takes a manual address (#0063).
- Address rules (#0063): App Transport Security stays at the local-network exemption, so plain `http`/`ws` works for `.local` names, unqualified names and IP addresses (Tailscale `100.x` included). Any other address, a public DNS name or a Tailscale MagicDNS `*.ts.net` name, must be `https` (reached as `wss`), for example through `tailscale serve`. A bare non-local host defaults to `https`.

### Reference implementations worth reading
- `github.com/music-assistant/client`: official Python client (handshake, models, every controller). Primary source for message shapes.
- `github.com/Niek/MusicAssistantMenuBar`: Swift menu bar controller. WS client at `/ws`, Keychain token storage, Bonjour discovery, transport + volume. Closest existing Swift code.
- `github.com/music-assistant/desktop-app`: official Tauri desktop app; plays locally via Sendspin on macOS. Reference for local playback behavior.

## 5. App architecture

### 5.1 Backend abstraction
```swift
protocol MusicBackend {
    func connect() async throws
    func search(_ query: String) async throws -> SearchResults
    func artists(page: Page) async throws -> [Artist]
    func albums(artist: Artist?, page: Page) async throws -> [Album]
    func tracks(album: Album) async throws -> [Track]
    func playlists() async throws -> [Playlist]
    func outputs() async throws -> [OutputDevice]          // MA players / Plex clients
    func play(_ items: [MediaRef], on output: OutputDevice) async throws
    func transport(_ cmd: TransportCommand, on output: OutputDevice) async throws
    var nowPlaying: AsyncStream<NowPlaying> { get }
}
final class MusicAssistantBackend: MusicBackend { … }  // default
final class PlexBackend: MusicBackend { … }            // existing/alternate
```
- Settings > Library Source: **Music Assistant (default)** | Plex. Settings › Music Assistant holds a list of servers (URL, learned `server_id`, one Keychain token item per server, keyed by the configuration's UUID); SkinAmp picks the server automatically (#0075, below).
- Skin/UI layer depends only on `MusicBackend` and domain models, never on MA or Plex types.

### 5.2 Two output modes under MA
1. **Remote speakers (HomePods, other AirPlay):** the app is only a controller. MA streams AirPlay directly from the server; the Mac sends `player_queues/play_media` and transport commands and renders now-playing from events. No audio passes through the Mac.
2. **This Mac:** the app registers as a **Sendspin player** so MA streams to it and it can be grouped in sync with HomePods.
   - No Swift Sendspin SDK exists. Options: wrap `github.com/Sendspin/sendspin-cpp` (supports macOS, decodes FLAC/PCM, optional Opus, Noise encryption built in, Apache 2.0) via Swift C++ interop; or port the client side using the spec at `github.com/Sendspin/spec` plus `Sendspin/time-filter` for clock sync.
   - Sendspin is a technical preview (RC1); expect protocol changes. Audio to Sendspin players is 16-bit. Players must pair (PIN/token) unless "allow unpaired" is set on the server.
   - Smoke test target: run `sendspin-cpp-cli` (`sendspin-cli -n test`) on the Mac first to confirm the server sees a Mac player before writing app code.

Ship mode 1 first. Mode 2 is the larger, riskier piece.

### 5.3 Optional: Home Assistant path
Only if HA is the integration point later: HA WebSocket API, call `music_assistant.search` / `get_library` / `play_media` / `get_queue` with responses, and use `media_player.*` entities. Note HA entities duplicate any HA players imported into MA. Not recommended as the app's primary path.

## 6. Implementation tasks for Claude Code

1. **Spike script** (Swift CLI or `curl` + `websocat`): connect to `/ws`, log the server info message, authenticate with the token, call `player_queues/all` and one library listing. Record the real message shapes into `docs/ma-protocol-notes.md`. Resolve every VERIFY item above.
2. **`MusicAssistantKit` Swift package:** `URLSessionWebSocketTask` connection actor, `message_id` correlation with continuations, partial-result assembly, event `AsyncStream`, auto-reconnect with backoff and re-auth, Codable models for Artist/Album/Track/Playlist/Player/Queue. Unit tests with recorded JSON fixtures from step 1.
3. **Discovery + settings:** Bonjour browse, manual host field, token entry stored in Keychain, connection status indicator, backend picker defaulting to Music Assistant.
4. **`MusicBackend` protocol** and adapters for MA and Plex; move existing Plex code behind it.
5. **Controller mode:** output picker listing MA players (HomePods), play album/track/playlist, transport, volume, now-playing + artwork from events.
6. **Local playback mode (Sendspin):** separate milestone after 1 through 5 are solid.

   A plain HTTP fetch of a track was ruled out in #0089: Music Assistant 2.10.6 has no full-track URL for a client that is not a player; `music/tracks/preview` gives a 30 s AAC sample at most. See `ma-protocol-notes.md` section 13.

Acceptance for milestone 1 (steps 1 to 5): with the Mac on the home LAN, the app discovers MA, authenticates, browses the Plex-backed library, plays an album on a HomePod, and reflects play/pause/track changes made from the MA web UI within ~1 s.

## 7. Known gotchas
- Same flat L2 network for MA and all speakers; no VLANs, no restrictive firewall.
- HomePod silent playback: fix the Home app speaker access setting (section 3).
- Queues/playlists over ~1000 items get slow, especially on a Pi.
- First sync of a large library is slow (metadata API rate limits); later syncs are faster.
- Remote (off-LAN) use: Sendspin needs the same network; over Tailscale, controller mode should work against the MA host's tailnet IP, but AirPlay targets are still at home.

### Several servers (#0075)

- **Order.** Only tested servers (with a learned `server_id`) are candidates. Servers tied to the current Wi-Fi network (Settings › Music Assistant › Wi-Fi Networks) come first, in list order; then every other one, in list order. Tailscale addresses need no special case: they are tried like any other.
- **Probe.** Every candidate gets an unauthenticated `GET /info` at once (3 s timeout each; two servers at one URL share one fetch). The winner is the highest-ranked candidate that answered with **its own stored `server_id`**; a lower-ranked success waits for higher-ranked probes to finish or time out. A different server at the address is a mismatch and never receives the token. The probes reveal to each configured server that the client exists; they carry nothing else.
- **When.** Never at launch. The first resolution happens when the Library connects or #0067 probes Music Assistant. After that: a network path change (`NWPathMonitor`, debounced 2 s), a Settings edit, the Mac waking, a client that failed or kept reconnecting for more than 10 s, or a browse failure. The same winner causes no reload; a new winner disconnects and reloads the Library (or lets #0067 restore Music Assistant). Playback on This Mac is never touched. None reachable: #0067 falls back to the local folder. Renaming a server only relabels the winner and the reason, with no re-check, and the Library subtitle leaves out the reason until the first check (#0092).
- **Wi-Fi name.** macOS returns it only with Location access. SkinAmp asks only when the user presses "Use Current Network" (the app has the `com.apple.security.personal-information.location` entitlement, needed under the hardened runtime). Without access, the order is the list order and the probe decides.
- **Privacy.** The "why" text ("Home — on network X", "Studio — via Tailscale", "No Music Assistant server reachable") is UI only. Logs carry decision kinds and counts, never a name, address, network name, server id or token.

## Sources
- HA integration: https://www.home-assistant.io/integrations/music_assistant/
- MA install: https://www.music-assistant.io/installation/
- MA API: https://www.music-assistant.io/api/
- Plex provider: https://www.music-assistant.io/music-providers/plex/
- AirPlay provider: https://www.music-assistant.io/player-support/airplay/
- Sendspin in MA: https://www.music-assistant.io/player-support/sendspin/
- Sendspin SDKs: https://www.sendspin-audio.com/build/sdks/
- Desktop app: https://www.music-assistant.io/companion-app/
- Python client: https://pypi.org/project/music-assistant-client/ and https://github.com/music-assistant/client
- Swift reference: https://github.com/Niek/MusicAssistantMenuBar

# Sendspin notes (#0066)

What Roadie needs to know to play Music Assistant audio on this Mac as a Sendspin player. Researched and probed on 2026-10-19 for #0066; the child issues #0105 to #0109 implement it.

## Sources and versions relied on

| Source | Version read | Used for |
|---|---|---|
| [Sendspin/spec](https://github.com/Sendspin/spec) `README.md` | `main` at `01f2f34a` (2026-10-19); tag `1.0.0-rc1` is `671a34d4` (2026-09-17) | message semantics, player role, clock sync, sync accuracy rules, the current (encrypted) wire |
| [Sendspin/aiosendspin](https://github.com/Sendspin/aiosendspin) | tag `9.1.1` (what Music Assistant 2.10.6 pins: `aiosendspin[server]==9.1.1`) | the wire the user's server actually speaks: `server/connection.py`, `models/core.py`, `models/player.py`, `noise/*` |
| aiosendspin | tag `10.2.1` (what MA `dev`, 2.11, pins) | which older clients a newer server still accepts, and how |
| [music-assistant/server](https://github.com/music-assistant/server) | tag `2.10.6` | `controllers/webserver/sendspin_proxy.py`, `providers/sendspin/{provider,player,constants}.py`, `controllers/players/README.md`, `providers/universal_player/README.md` |
| [music-assistant/desktop-app](https://github.com/music-assistant/desktop-app) | `main` (2026-10-19), `src-tauri/src/sendspin/mod.rs`; uses [sendspin-rs](https://github.com/Sendspin/sendspin-rs) tag `v0.3.8` | how MA's own desktop player connects (proxy + legacy wire) |
| [Sendspin/time-filter](https://github.com/Sendspin/time-filter) | `main` at `531e2707` (2026-10-14), `cpp/sendspin_time_filter.cpp` | the clock filter to port |
| [Sendspin/sendspin-cpp](https://github.com/Sendspin/sendspin-cpp) | not used | wrapping C++ was not needed once the legacy wire turned out to be small |
| Live probe, `scripts/probe-sendspin.py` | server 2.10.6, schema 65 | everything marked **(probed)** below; scrubbed result in [ma-protocol/sendspin-probe.json](ma-protocol/sendspin-probe.json) |

The spec moves weekly (encryption, pairing, the 13-byte audio header and fragment id 1 all landed between August and October 2026) and servers lag it. **Design to what the server speaks, not to spec `main`.**

## 1. Two wires

| | Legacy (unencrypted) | Current spec (Noise) |
|---|---|---|
| First frame | `client/hello` (text) carrying `client_id` and `version: 1` | `client/init` (text), then `server/init`, two `noise/handshake` frames, then everything encrypted in binary frames |
| Server reply | one legacy `server/hello` (`server_id`, `name`, `version`, `active_roles`, `connection_reason`); no `server/activate` | `server/hello` (`name`), `client/hello`, `server/activate` (`activities`, `active_roles`) |
| Audio header | 9 bytes: type `4`, int64 BE timestamp | spec `main`: 13 bytes (adds uint32 BE `send_ahead`); aiosendspin 9.1.1 still 9 |
| Who accepts it | MA 2.10.6 (`allow_unencrypted` = hidden provider setting `allow_legacy_clients`, default **true**, labelled "temporary") and MA dev / aiosendspin 10.x (same setting; such clients are "flagged noncompliant" and get the 9-byte header and legacy fragment framing) | MA 2.10.6 speaks the *9.1.1* flavour (msg-1 payload `{psk_id}` only, fragment types 2/3, `trust_level` in hello); 10.x speaks rc1 (`psk_category`, fragment id 1, 13-byte header) and a 10.x client cannot reach a 9.1.1 server |
| Auth | through the MA proxy: the MA token | Noise `KKpsk2` with a Sentinel, pairing or long-term PSK; unpaired access needs operator approval (MA 2.10.6 auto-approves any client advertising `unpaired_access.enabled`) |

**Roadie uses the legacy wire through the authenticated proxy**, as MA's own desktop app does (sendspin-rs v0.3.8 has no Noise code and connects to `/sendspin` with the MA token). It works on 2.10.6 today and on 2.11 as published. Risk: MA labels `allow_legacy_clients` temporary. The encrypted wire is a follow-up to plan when MA announces the removal (the desktop app would break at the same moment). Keep the wire choice behind one type (`SendspinWire`) so the 13-byte header and Noise can be added without touching the rest.

## 2. Connection (probed)

- URL: the configured Music Assistant base URL with path `/sendspin` (`ws://` for `http://`, `wss://` for `https://`, any reverse-proxy path prefix kept). Same host and port as the API, so no new port, firewall rule or Bonjour entry.
- First text frame: `{"type": "auth", "token": "<MA long-lived token>", "client_id": "<sendspin client id>"}`. The proxy answers `{"type": "auth_ok"}` (probed, 4 ms) and from then on forwards text and binary frames verbatim to the internal Sendspin server (`ws://127.0.0.1:8927/sendspin` inside MA). A bad or missing token closes the socket with code 4001 (reason text such as `Invalid or expired token`); a 10 s wait without auth closes with 4001 too. The `client_id` makes MA whitelist the player for this user's sessions (`set_sendspin_player_for_token`).
- The proxy's own heartbeat is 25 s (WebSocket ping); answer pings (URLSession does).
- Direct `ws://<host>:8927/sendspin` is reachable from this Mac (probed: TCP connect only) but unauthenticated; not used.

## 3. Handshake (probed, legacy wire)

Client → server (after `auth_ok`):

```json
{"type": "client/hello", "payload": {
  "client_id": "skinamp-probe", "name": "SkinAmp probe", "version": 1,
  "supported_roles": ["player@v1"],
  "device_info": {"product_name": "SkinAmp", "manufacturer": "SkinAmp", "software_version": "probe"},
  "player@v1_support": {
    "supported_formats": [{"codec": "pcm", "channels": 2, "sample_rate": 48000, "bit_depth": 16}],
    "buffer_capacity": 1048576,
    "supported_commands": ["volume", "mute"]}}}
```

Server → client, 3 ms later:

```json
{"type": "server/hello", "payload": {"active_roles": ["player@v1"], "connection_reason": "discovery",
  "name": "Music Assistant", "server_id": "<43-char base64url key>", "version": 1}}
```

- `client_id` on the legacy wire is any stable string (MA uses it as the Sendspin player id). It must never have connected encrypted before (MA refuses a legacy hello that claims a paired or approved id: downgrade protection).
- `player@v1_support.supported_commands` (`volume`, `mute`) belongs in the hello on this wire (spec `main` moved it to `client/state`). `supported_formats` must list `pcm` or `flac`; a client that lists one rate and channel count gets the server's resampler.
- Roles: only `player@v1`. Metadata, controller and artwork come from the MA API Roadie already uses.
- The initial `client/state` is due within **5 s** of the hello, or the server flags the client noncompliant (lenient: it marks it connected anyway).

## 4. Clock sync (probed)

- `client/time {client_transmitted}` → `server/time {client_transmitted, server_received, server_transmitted}`, all integer microseconds; the server's clock is its own monotonic clock. Probe: 5/5 replies, RTT 0.9 to 2.0 ms, offset spread 54 to 262 µs on this LAN.
- With T1 = sent (client µs), T2 = `server_received`, T3 = `server_transmitted`, T4 = received: `measurement = ((T2 − T1) + (T3 − T4)) / 2`, `max_error = ((T4 − T1) − (T3 − T2)) / 2`, `time_added = T4`.
- Filter: port `SendspinTimeFilter` from time-filter `main` (2-state Kalman on offset and drift; defaults `process_std_dev 0`, `drift_process_std_dev 1e-11`, `forget_factor 2`, `adaptive_cutoff 3`, `min_samples 100`, `drift_significance_threshold 2`, `max_error_scale 0.5`). It ignores samples with non-increasing `time_added` or `max_error <= 0`. `compute_client_time(server) = round((server − offset + drift·last_update) / (1 + drift))` with drift used only when significant.
- Cadence (time-filter "Recommended Usage"): a burst of 8 sequential exchanges, each waiting for its reply, feeding only the lowest-`max_error` sample; the first burst at connect, then every 10 s. sendspin-rs instead sends two samples 10 ms apart then one per second; either is fine.
- A player must not report `available: true` until the filter has converged enough to schedule (Roadie: at least two accepted samples, the first burst finished).

## 5. Player state and commands

- `client/state` on this wire (aiosendspin 9.1.1 keys): `{"available": true, "player": {"volume": 0-100, "muted": bool, "static_delay_ms": 0, "required_lead_time_ms": n, "min_buffer_ms": n, "supported_commands": []}}`. `static_delay_ms` is the old name of `output_delay_ms`; the state-level `supported_commands` may only hold `set_static_delay`. Every state message carries `available` and the full player object. Send it whenever volume or mute changes, including changes made in Roadie.
- `server/command {"player": {"command": "volume", "volume": n}}`, `{"command": "mute", "mute": bool}`, `{"command": "set_static_delay", "static_delay_ms": n}` (only if offered). Apply, then report the new state.
- Volume is perceived loudness 0 to 100; the spec suggests `amplitude = (volume/100)^1.5`. Roadie's own slider is linear (`Player.volume` 0…1, Winamp behaviour); map `volume = round(Player.volume × 100)` both ways and leave the curve to the slider.
- `group/update {playback_state, group_id, group_name?}` (probed: `{"group_id": "<uuid>", "playback_state": "stopped"}` right after the state; no `group_name`). `playback_state` may be `playing`, `paused` or `stopped` on this wire.
- `server/state` carries only roles Roadie does not ask for (metadata, controller, color); ignore unknown types and fields.
- `client/goodbye {"reason": "shutdown" | "restart" | "user_request" | "another_server"}` before a deliberate close.

## 6. Stream

- `stream/start {"server_transmitted"?, "player": {"codec", "sample_rate", "channels", "bit_depth", "codec_header"?}}`; a second `stream/start` during a stream changes the format for chunks that follow, on the same timeline.
- Binary audio (legacy): byte 0 = `4`, bytes 1–8 = int64 big-endian server time (µs) at which the chunk's first frame must leave the audio port, then the payload. PCM is signed little-endian interleaved (24-bit packed in 3 bytes). Chunks carry whole frames, 15 to 150 ms each. Late chunks (timestamp already past) should be dropped.
- `stream/clear {"roles": ["player"]}`: drop everything buffered, keep the stream; sent for seeks and track jumps (MA streams the whole queue as one continuous stream, so track changes are gapless by construction and need no client work).
- `stream/end {"roles"?}`: stop output and clear; sent when the queue is finished or the player leaves.
- Lead: the server sends audio at least `min_buffer_ms + static_delay_ms` ahead and fills up to `buffer_capacity` bytes for buffered sources. 1 MiB is about 5.4 s of 48 kHz stereo 16-bit PCM.
- Sync rules (spec "Playback Synchronization"): stay within ±1 ms of the filter's prediction in steady state, correct with inaudible steps (drop or duplicate one frame per chunk at 44.1/48 kHz, at most 0.5 % speed change), and snap in one step at start, after `stream/clear` or after an underrun.
- Codecs: PCM only for now (FLAC needs a FLAC frame decoder fed with the STREAMINFO `codec_header`; Opus is optional for servers and patent-encumbered). PCM costs about 1.5 Mbit/s on the LAN.

## 7. How the player appears in Music Assistant (probed)

- A Sendspin client whose `device_info` does not look like MA's own web or app player registers as a **protocol player** (`PlayerType.PROTOCOL`, hidden). About **15 s** after its first connect MA wraps it in a **universal player**: provider `universal_player`, `player_id` `up` + 8 hex characters (not the client id), `name` = the hello's `name`, `type` `player`, `supported_features` `volume_mute`, `volume_set`, `set_members` (no `play_media`: MA routes playback to the protocol), and `output_protocols` containing `{"output_protocol_id": "<client_id>", "protocol_domain": "sendspin", "is_native": false, "available": true}`. `volume_control` and `mute_control` name the client id. After the client disconnects the universal player stays listed with `available: false`; on the next connect it is reused at once (probed: listed on the first poll).
- So Roadie finds "its" MA player by scanning `players/all` for an entry whose `output_protocols` has `output_protocol_id == client_id` (or whose `player_id == client_id`, the shape a standalone player would have), and sends `player_queues/play_media`, transport and grouping commands to that player's id.
- Alternative not taken: `device_info.manufacturer == "Music Assistant"` (or `product_name` `Web Player`, `Mobile Application`, `PWA`, `Web Browser`) makes MA treat the client as its own web/app player: a standalone `sendspin` player under the client id at once, but hidden by default, private and not exposed to Home Assistant. That is a heuristic meant for MA's own apps; Roadie identifies as itself.
- Grouping with a HomePod is done in MA (`set_members` on the universal player or the HomePod); MA's Sendspin server then times both. Roadie needs no grouping UI for #0066.

## 8. Left on the server by the probe

The probe registered a Sendspin client `skinamp-probe`, so the server now has a universal player named **SkinAmp probe** (unavailable while nothing is connected). It is harmless; remove it in Music Assistant (Settings › Players) if it is in the way. Roadie itself registers under its own client id and name.

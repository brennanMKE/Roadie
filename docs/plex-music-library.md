# Playing Music from Plex on joe

How the player can reach the Plex Media Server on joe, browse its Music library, and play
tracks. It also proposes a Settings screen where the user enters their own server's hostname
or IP.

Everything under "What the server looks like" was checked against the live server on
2026-10-12. The sign-in flow was not tested and is marked as such (#0014). The macOS
networking checks are recorded under "macOS networking".

## What the server looks like

| | |
|---|---|
| Host | `joe`, a Mac mini (Plex name `brennan-mac-mini-m1`) |
| Version | Plex Media Server 1.43.4 |
| Port | 32400. HTTP and HTTPS both answer on it |
| Music library | Section **5**, type `artist`, at `/Volumes/Media/Media/Music` |
| Other libraries | Movies (section 4), TV Shows (section 2). The player ignores them |
| Contents | About 21 artists, 31 albums and 150 tracks. Some are podcasts |
| Formats | 149 MP3 and 1 AAC in MP4. AVFoundation plays both |

Server-side details, such as the rip pipeline, how to search, and the database, are
documented in the Homelab repo: `~/Developer/Homelab/docs/plex-search-api.md` and
`plex-library-on-joe.md`.

## Addresses that reach it

| Address | Works from | Notes |
|---|---|---|
| `http://joe:32400` | Any machine on the tailnet | Resolved by Tailscale MagicDNS |
| `http://brennan-mac-mini-m1.local:32400` | The home LAN | Bonjour name. Needs no Tailscale |
| `http://<LAN IP>:32400` | The home LAN | The LAN IP is DHCP and has moved before, so do not hard-code it |
| `https://joe:32400` | Nowhere | The certificate is issued for `*.<hash>.plex.direct`, so validation fails under any other name |

**Use plain HTTP when the user types a hostname or IP.** To use HTTPS, take the
`plex.direct` URI that plex.tv publishes for the server; see the sign-in section below.

## Authentication

Every endpoint except `/identity` requires a token:

| Request | Result |
|---|---|
| `GET /identity`, no token | 200. Returns the server's `machineIdentifier` and version |
| `GET /library/sections`, no token | **401** |
| Same, with an `X-Plex-Token` header | 200 |

The token can go in an `X-Plex-Token` header or a `?X-Plex-Token=` query parameter. Use
the header for API calls. Use the query parameter only where a URL has to carry it, such
as an `AVURLAsset`.

**For development**, the owner's token can be read off joe:

```sh
T=$(ssh joe 'defaults read com.plexapp.plexmediaserver PlexOnlineToken')
```

The app must not depend on this, and the token must never be committed or logged.

**For the app**, use Plex's PIN sign-in. *This flow was not tested against the server.*

1. `POST https://plex.tv/api/v2/pins?strong=true`, with `X-Plex-Product` and a stable
   `X-Plex-Client-Identifier` (a UUID generated once and stored). The response contains
   `id` and `code`.
2. Open `https://app.plex.tv/auth#?clientID=<identifier>&code=<code>&context[device][product]=<product>`
   in the browser.
3. Poll `GET https://plex.tv/api/v2/pins/<id>` until `authToken` is set.
4. Optional: `GET https://clients.plex.tv/api/v2/resources?includeHttps=1` lists each
   server with its connections. For joe it returns local and remote `https://…plex.direct`
   URIs, plus a relay. Those URIs give the app working HTTPS, and remote access when away
   from home.

Store the token in the **Keychain**, not `UserDefaults`.

## Browsing the library

Send `Accept: application/json`; without it, responses are XML. Every list is under
`MediaContainer.Metadata`.

| Step | Request |
|---|---|
| Find music libraries | `GET /library/sections`, then keep the entries where `type == "artist"` |
| Artists | `GET /library/sections/5/all?type=8` |
| Albums | `GET /library/sections/5/all?type=9`, or `/library/metadata/<artistKey>/children` |
| Tracks | `GET /library/sections/5/all?type=10`, or `/library/metadata/<albumKey>/children` |
| Search | `GET /library/sections/5/all?type=10&title=<text>` |

**Do not hard-code section 5.** Another user's server will number its sections differently.

To page through results, send the `X-Plex-Container-Start` and `X-Plex-Container-Size`
headers. The response gives `size` for the page and `totalSize` for the whole result.

The library data needs some cleanup in the UI:

- The same artist can appear under two spellings, such as `AJ & Jordan` and
  `AJ and Jordan`, or with and without a trailing `;`.
- Albums may have no `thumb`, so plan for a placeholder.
- Tracks include long podcast episodes; one is 53 minutes long.

## Playing a track

Each track has a `Media[0].Part[0].key`, such as `/library/parts/3048/…/file.mp3`. A request
for it returns the original file:

```
GET http://joe:32400/library/parts/<id>/<n>/file.mp3   (with X-Plex-Token)
→ 206 Partial Content, Accept-Ranges: bytes, Content-Type: audio/mpeg
```

The server honors byte ranges, so seeking works.

**This conflicts with the player's AVAudioEngine design.** `AVAudioPlayerNode` plays from
an `AVAudioFile`, and an `AVAudioFile` can only open a local file, not a URL. There are two
options:

1. **Download, then play (recommended).** Fetch the part to a cache file with
   `URLSession`, then schedule it like any local file. The EQ and visualizer work unchanged.
   Tracks are small (one podcast episode is 19 MB), so a short wait before playback is
   acceptable. A later version can play while the download continues.
2. **`AVPlayer` with the part URL.** It streams immediately, but its output does not pass
   through the AVAudioEngine graph, so the 10-band EQ and the analyzer tap would need an
   `MTAudioProcessingTap`.

**Decision (2026-10-12): option 1.** Tracks are downloaded into a bounded on-disk cache that
evicts the least recently used files, and the next queued track is prefetched. See the Track
cache section of [plan.md](plan.md) and issue [#0013](../issues/0013.md).

Plex also has a transcoding endpoint (`/music/:/transcode/universal/…`). It is only needed
for formats AVFoundation can't play, and this library has none.

## Settings screen

A **Plex** section in Settings:

| Field | Stored in | Notes |
|---|---|---|
| Server address | `UserDefaults` | Free text, placeholder `joe` or `192.168.1.10` |
| Account | Keychain (generic password, service `com.brennanmke.SkinAmp.plex`, account `plex.tv`, login keychain) | A **Sign in with Plex** button runs the PIN flow. Also offer a "paste a token" field as a fallback |
| Music library | `UserDefaults` | A picker, filled once the connection succeeds. Hidden when there is only one music library |
| Server identity | `UserDefaults` | The `machineIdentifier` from `/identity`. Not shown to the user |

**Normalize the address.** Each of these inputs should resolve to `http://joe:32400`:

```
joe              → http://joe:32400
joe:32400        → http://joe:32400
http://joe:32400 → unchanged
192.168.1.10     → http://192.168.1.10:32400
```

Add `http://` when no scheme is given and `:32400` when no port is given, and accept
`https://` when the user types it.

A trailing slash, surrounding whitespace, a query string and a fragment are dropped (so a pasted
`?X-Plex-Token=` never becomes part of the address); a custom port is kept; a URL with a user name or
password is rejected. A Plex Web link (`…/web/index.html`) is cut back to the server.

**Test the connection** with three requests. Each failure gets a different message:

| Check | Failure | Message |
|---|---|---|
| `GET /identity`, no token | No response | "Can't reach the server. Check the address, whether you're on the home network or Tailscale, and that SkinAmp is allowed under System Settings › Privacy & Security › Local Network." |
| `GET /identity`, no token | ATS refused plain `http` (`-1022`) | "Plain http isn't allowed for this address. Use a short name like joe, a .local name, an IP address, or an https:// address." |
| `GET /identity`, no token | Answered, but not Plex (404, HTML, 500) | "Can't reach the server. Check the address, and whether you're on the home network or Tailscale." |
| `GET /library/sections`, with token | 401 | "Signed in, but this account can't access this server." |
| Any section with `type == "artist"` | None found | "This server has no music library." |

Save the `machineIdentifier`. If a later connection to the same address reports a
different one, the address now points to another server. Clear the selected library rather
than showing the wrong server's music.

## macOS networking

The keys are set in `project.yml` (`NSAppTransportSecurity.NSAllowsLocalNetworking`,
`NSLocalNetworkUsageDescription`) and checked on every VM run by `scripts/check-info-plist.sh`.
The connections themselves are checked by hand on the host; the results are in the table below
and are `pending` until they are recorded.

- **App Transport Security.** Plain HTTP is blocked by default. Setting
  `NSAppTransportSecurity` → `NSAllowsLocalNetworking = YES` covers unqualified names
  (`joe`), `.local` names and IP addresses. It does **not** cover a full Tailscale name
  such as `joe.<tailnet>.ts.net`, which stays blocked over HTTP; the user sees "Plain http
  isn't allowed for this address…" with network error -1022. For those, use the
  `plex.direct` HTTPS URI, or ask users to enter the short name.
- **Local Network privacy (macOS 15 and later).** The first connection to a LAN address
  shows a system permission prompt. Add `NSLocalNetworkUsageDescription` to the Info.plist
  so the prompt explains why. If the user denies it, LAN connections fail in the same way
  as an unreachable server, so the "can't reach" message ends with "…and that SkinAmp is
  allowed under System Settings › Privacy & Security › Local Network."
- **Sandbox.** The app is unsandboxed for now (`project.yml`). If App Sandbox is turned on,
  it needs `com.apple.security.network.client`.

| Address | Expected | Result |
|---|---|---|
| `joe` | Connected; no Local Network prompt when `joe` resolves to a Tailscale address | pending |
| `brennan-mac-mini-m1.local` | Local Network prompt once (text = `NSLocalNetworkUsageDescription`), then Connected | pending |
| LAN IP (not written down; it is DHCP) | Connected, no second prompt | pending |
| `joe.<tailnet>.ts.net` over `http` | "Plain http isn't allowed…", detail `-1022` | pending |
| `.local` or IP with Local Network off for SkinAmp | "Can't reach the server… Local Network.", detail code recorded here | pending |

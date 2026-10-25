#!/usr/bin/python3 -I
"""Records Music Assistant protocol fixtures for Roadie (#0060). Host only, network only, read-only.

Run:   /usr/bin/python3 -I scripts/record-ma-fixtures.py [--out DIR] [--events-seconds N]
Check: /usr/bin/python3 -I scripts/record-ma-fixtures.py --check
Live:  /usr/bin/python3 -I scripts/record-ma-fixtures.py --check-live   (read-only drift check, #0061)
Audio: /usr/bin/python3 -I scripts/record-ma-fixtures.py --probe-audio [--write] [--no-wait]   (per-track audio over HTTP, #0089)
Writes: /usr/bin/python3 -I scripts/record-ma-fixtures.py --record-playlist-writes [--out DIR]   (opt-in, #0133)
Queue: /usr/bin/python3 -I scripts/record-ma-fixtures.py --record-queue [--queue-id ID] [--events-seconds N]   (read-only, a loaded and playing queue, #0196)

Reads MUSIC_ASSISTANT_URL and MUSIC_ASSISTANT_TOKEN from .env itself. The token lives in one
variable, goes only into the `auth` frame and into Authorization headers of artwork probes, and is
never put in argv, the environment, a URL, a log line or a file. Sends only the commands in ALLOWED:
nothing that plays, pauses, seeks, changes volume, groups players, syncs or edits anything.
The one exception is the opt-in --record-playlist-writes run (#0133): it may also send ALLOWED_WRITES,
and only against a throwaway playlist it creates itself and deletes in a `finally`; a favorite it
adds is removed again, and skipped entirely when the track already was a favorite.
Python 3.9 compatible (Apple's /usr/bin/python3).
"""
import base64
import hashlib
import http.client
import json
import os
import re
import select
import shutil
import socket
import ssl
import struct
import subprocess
import sys
import time
import urllib.parse

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
FIXTURE_REL = "Packages/PlayerKit/Sources/MusicAssistantKitStub/Fixtures"
DOCS_REL = "docs/ma-protocol"
SENDSPIN_FIXTURE_REL = "Packages/PlayerKit/Tests/SendspinKitTests/Fixtures"
NOTES_REL = "docs/ma-protocol-notes.md"

# The only commands call() will send. Everything is a read.
ALLOWED = frozenset([
    "auth", "time", "info", "auth/me", "providers",
    "players/all", "players/get", "player_queues/all", "player_queues/get",
    "player_queues/get_active_queue", "player_queues/items",
    "music/artists/count", "music/albums/count", "music/tracks/count", "music/playlists/count",
    "music/artists/library_items", "music/albums/library_items",
    "music/tracks/library_items", "music/playlists/library_items",
    "music/artists/artist_albums", "music/albums/album_tracks", "music/albums/get",
    "music/playlists/playlist_tracks", "music/item_by_uri", "music/search",
    "music/tracks/preview",  # #0089: mints a preview URL; a read (library.read), plays nothing
    # #0133 (playlists design §1.5): reads only.
    "music/playlists/get", "music/recommendations", "music/recommendations/items",
    "music/recently_played_items", "music/recently_added_tracks",
    "music/radios/count", "music/radios/library_items", "music/playlists/export_playlist",
])
# #0133: sent only by --record-playlist-writes, only on the throwaway playlist it creates.
ALLOWED_WRITES = frozenset([
    "music/playlists/create_playlist", "music/playlists/add_playlist_tracks",
    "music/playlists/remove_playlist_tracks", "music/playlists/update",
    "music/playlists/move_playlist_track",  # absent on 2.10.6: the error frame is the recording
    "music/favorites/add_item", "music/favorites/remove_item", "music/library/remove_item",
])
# Fixtures only the writes run produces; the default run leaves them in place.
WRITE_FIXTURES = frozenset([
    "playlist-create", "playlist-add-tracks", "playlist-tracks-after-add", "playlist-remove-tracks",
    "playlist-tracks-after-remove", "playlist-update", "favorite-add", "favorite-remove",
    "error-unknown-command-move", "playlist-delete", "events-playlists",
])
# Fixtures only the --record-queue run produces (#0196); the default run leaves them in place.
QUEUE_FIXTURES = frozenset([
    "players-all-playing", "player-queue-get-loaded", "player-queue-items-loaded",
    "player-queue-items-page2", "events-queue",
])
QUEUE_PAGE = 50
# Items kept per result frame (the real counts go to original_item_counts).
TRUNCATE = {"playlist-tracks": 5, "player-queue-items-loaded": 50, "player-queue-items-page2": 50,
            "playlist-tracks-after-add": 5, "playlist-tracks-after-remove": 5}
# Error-envelope probes. Harmless: an unknown command, never the real token on a failing path.
PROBES = frozenset(["roadie/no_such_command"])

FAKE_SERVER_ID = "0123456789abcdef0123456789abcdef"
FAKE_UUID = "00000000-0000-0000-0000-000000000000"
FAKE_HOST = "ma.example"
SECRET_KEYS = {"token", "access_token", "token_hash", "api_key", "password"}
BULK_TRUNC = {"review", "lyrics", "lrc_lyrics", "transcript", "description"}
BULK_EMPTY = {"transcript_cues", "chapters"}
PRIV_IP = re.compile(r"\b(?:10\.\d{1,3}\.\d{1,3}\.\d{1,3}|192\.168\.\d{1,3}\.\d{1,3}"
                     r"|172\.(?:1[6-9]|2\d|3[01])\.\d{1,3}\.\d{1,3}|169\.254\.\d{1,3}\.\d{1,3})\b")
LOCAL_NAME = re.compile(r"[A-Za-z0-9_-]+(?:\.[A-Za-z0-9_-]+)*\.local\b", re.I)
TOKEN_QS = re.compile(r"(?i)(?:[?&]|%3F|%26)(?:x-plex-token|token)(?:=|%3D)[^&\s\"']*")


def die(msg):
    print("error: " + msg, file=sys.stderr)
    sys.exit(1)


def read_env():
    path = os.path.join(ROOT, ".env")
    vals = {}
    try:
        with open(path, encoding="utf-8") as f:
            for line in f:
                line = line.strip()
                if not line or line.startswith("#") or "=" not in line:
                    continue
                k, v = line.split("=", 1)
                k = k.strip()
                if k.startswith("export "):
                    k = k[7:].strip()
                vals[k] = v.strip().strip("'\"").strip()
        url = vals.get("MUSIC_ASSISTANT_URL", "").rstrip("/")
        token = vals.get("MUSIC_ASSISTANT_TOKEN", "")
    except OSError:
        die(".env not readable")
    if not url or not token:
        die(".env must define MUSIC_ASSISTANT_URL and MUSIC_ASSISTANT_TOKEN")
    if "://" not in url:
        url = "http://" + url
    # ws:// and wss:// name the same server as http:// and https://.
    scheme, rest = url.split("://", 1)
    url = {"ws": "http", "wss": "https"}.get(scheme.lower(), scheme.lower()) + "://" + rest
    if not url.startswith(("http://", "https://")):
        die("MUSIC_ASSISTANT_URL must be http(s):// or ws(s)://")
    return url, token


# One TLS context for every https/wss connection (a Tailscale `tailscale serve` address, a reverse proxy).
# create_default_context() verifies the certificate chain and the host name; never relax it here.
TLS = ssl.create_default_context()


# ---------------------------------------------------------------- HTTP

def http_get(base, path_or_url, bearer=None, timeout=10, maxbytes=4000000):
    """GET without following redirects. Returns (status, content_type, body bytes)."""
    if path_or_url.startswith("http://") or path_or_url.startswith("https://"):
        u = urllib.parse.urlsplit(path_or_url)
        b = urllib.parse.urlsplit(base)
        target = urllib.parse.urlunsplit(("", "", u.path or "/", u.query, ""))
        scheme, netloc = b.scheme, b.netloc  # always talk to the configured host
    else:
        b = urllib.parse.urlsplit(base)
        scheme, netloc = b.scheme, b.netloc
        target = path_or_url
    prefix = urllib.parse.urlsplit(base).path.rstrip("/")  # a reverse-proxy path prefix, if any
    if prefix and not target.startswith(prefix + "/"):
        target = prefix + target
    if scheme == "https":
        conn = http.client.HTTPSConnection(netloc, timeout=timeout, context=TLS)
    else:
        conn = http.client.HTTPConnection(netloc, timeout=timeout)
    headers = {"Accept": "*/*", "User-Agent": "Roadie-recorder"}
    if bearer:
        headers["Authorization"] = "Bearer " + bearer
    try:
        conn.request("GET", target, headers=headers)
        r = conn.getresponse()
        body = r.read(maxbytes)
        return r.status, r.getheader("Content-Type", ""), body
    finally:
        conn.close()


# ---------------------------------------------------------------- WebSocket (RFC 6455, minimal)

class Closed(Exception):
    pass


class WS:
    def __init__(self, base, transcript, token, path="/ws"):
        self.transcript = transcript
        self.token = token
        self.pings = 0
        self.buf = b""
        self.frag = b""
        self.t0 = time.time()
        u = urllib.parse.urlsplit(base)
        secure = u.scheme == "https"
        port = u.port or (443 if secure else 80)
        sock = socket.create_connection((u.hostname, port), timeout=10)
        if secure:
            sock = TLS.wrap_socket(sock, server_hostname=u.hostname)
        self.sock = sock
        key = base64.b64encode(os.urandom(16)).decode()
        req = ("GET %s%s HTTP/1.1\r\nHost: %s\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
               "Sec-WebSocket-Key: %s\r\nSec-WebSocket-Version: 13\r\n\r\n" % (u.path.rstrip("/"), path, u.netloc, key))
        sock.sendall(req.encode())
        head = b""
        deadline = time.time() + 10
        while b"\r\n\r\n" not in head:
            if time.time() > deadline:
                raise Closed("handshake timeout")
            chunk = sock.recv(4096)
            if not chunk:
                raise Closed("closed during handshake")
            head += chunk
        head, self.buf = head.split(b"\r\n\r\n", 1)
        lines = head.decode("latin-1").split("\r\n")
        if " 101 " not in lines[0] + " ":
            raise Closed("upgrade refused: " + lines[0])
        accept = base64.b64encode(hashlib.sha1((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").encode()).digest()).decode()
        hdrs = {l.split(":", 1)[0].strip().lower(): l.split(":", 1)[1].strip() for l in lines[1:] if ":" in l}
        if hdrs.get("sec-websocket-accept") != accept:
            raise Closed("bad Sec-WebSocket-Accept")

    def log(self, direction, text):
        line = json.dumps({"t": round(time.time() - self.t0, 3), "dir": direction, "frame": text.replace(self.token, "<redacted>")})
        self.transcript.write(line + "\n")
        self.transcript.flush()

    def _send_frame(self, opcode, payload):
        hdr = bytes([0x80 | opcode])
        n = len(payload)
        if n < 126:
            hdr += bytes([0x80 | n])
        elif n < 65536:
            hdr += bytes([0x80 | 126]) + struct.pack(">H", n)
        else:
            hdr += bytes([0x80 | 127]) + struct.pack(">Q", n)
        mask = os.urandom(4)
        masked = bytes(b ^ mask[i % 4] for i, b in enumerate(payload))
        self.sock.sendall(hdr + mask + masked)

    def send_json(self, obj, redact_args=False):
        text = json.dumps(obj)
        self._send_frame(1, text.encode())
        self.log("out", text)

    def close(self):
        try:
            self._send_frame(8, struct.pack(">H", 1000))
            self.log("out", "<close 1000>")
        except OSError:
            pass
        try:
            self.sock.close()
        except OSError:
            pass

    def _try_parse(self):
        b = self.buf
        if len(b) < 2:
            return None
        fin = bool(b[0] & 0x80)
        op = b[0] & 0x0F
        masked = bool(b[1] & 0x80)
        n = b[1] & 0x7F
        i = 2
        if n == 126:
            if len(b) < 4:
                return None
            n = struct.unpack(">H", b[2:4])[0]
            i = 4
        elif n == 127:
            if len(b) < 10:
                return None
            n = struct.unpack(">Q", b[2:10])[0]
            i = 10
        if masked:
            i += 4
        if len(b) < i + n:
            return None
        payload = b[i:i + n]
        if masked:
            m = b[i - 4:i]
            payload = bytes(c ^ m[k % 4] for k, c in enumerate(payload))
        self.buf = b[i + n:]
        return fin, op, payload

    def recv(self, timeout):
        """Next complete text message as str, or None on timeout. Raises Closed."""
        deadline = time.time() + timeout
        while True:
            fr = self._try_parse()
            if fr is not None:
                fin, op, payload = fr
                if op == 9:
                    self.pings += 1
                    self.log("in", "<ping>")
                    self._send_frame(10, payload)
                    continue
                if op == 10:
                    self.log("in", "<pong>")
                    continue
                if op == 8:
                    self.log("in", "<close %r>" % (payload[:2],))
                    raise Closed("server closed")
                self.frag += payload
                if fin:
                    text = self.frag.decode("utf-8")
                    self.frag = b""
                    self.log("in", text)
                    return text
                continue
            remaining = deadline - time.time()
            if remaining <= 0:
                return None
            r, _, _ = select.select([self.sock], [], [], remaining)
            if not r:
                return None
            chunk = self.sock.recv(65536)
            if not chunk:
                raise Closed("connection closed")
            self.buf += chunk


class Session:
    """One authenticated or anonymous connection plus the id counter and pushed-event buffer."""

    def __init__(self, base, transcript, token, allowed=ALLOWED):
        self.ws = WS(base, transcript, token)
        self.next_id = 1
        self.events = []
        self.allowed = allowed

    def first_frame(self, timeout=10):
        t = self.ws.recv(timeout)
        return json.loads(t) if t else None

    def call(self, command, args=None, timeout=10, probe=False, _auth_token=None):
        if command not in self.allowed and not (probe and command in PROBES):
            raise RuntimeError("command not on the read-only allowlist: " + command)
        mid = str(self.next_id)
        self.next_id += 1
        self.ws.send_json({"message_id": mid, "command": command, "args": args or {}})
        frames = []
        deadline = time.time() + timeout
        while time.time() < deadline:
            t = self.ws.recv(max(0.05, deadline - time.time()))
            if t is None:
                break
            f = json.loads(t)
            if isinstance(f, dict) and f.get("message_id") == mid:
                frames.append(f)
                if not f.get("partial"):
                    break
            else:
                self.events.append((time.time(), f))
        return {"command": command, "args": args or {}, "frames": frames}


def result_of(rec):
    """Combine result payloads of a recorded call (list results concatenate)."""
    out = None
    for f in rec["frames"]:
        if "result" not in f:
            continue
        r = f["result"]
        if isinstance(r, list):
            out = (out or []) + r
        else:
            out = r
    return out


def is_error(rec):
    return any(("error_code" in f) or ("error" in f) for f in rec["frames"])


# ---------------------------------------------------------------- scrubbing

class Targets:
    def __init__(self, base, token, info):
        self.token = token
        self.hosts = set()
        self.names = []
        self.server_id = None
        self.username = None
        for u in [base] + [info.get(k) for k in ("base_url", "internal_url", "external_url")] if info else [base]:
            if not u or not isinstance(u, str):
                continue
            h = urllib.parse.urlsplit(u if "://" in u else "http://" + u).hostname
            if h:
                self.hosts.add(h)
        if info:
            self.server_id = info.get("server_id")
            n = info.get("name")
            if isinstance(n, str) and n and n != "Music Assistant":
                self.names.append(n)

    def scrub_str(self, s):
        s = s.replace(self.token, "<redacted>").replace(urllib.parse.quote(self.token, safe=""), "<redacted>")
        s = TOKEN_QS.sub("", s)
        for h in sorted(self.hosts, key=len, reverse=True):
            s = re.sub(re.escape(h), FAKE_HOST, s, flags=re.I)
            s = re.sub(re.escape(urllib.parse.quote(h, safe="")), FAKE_HOST, s, flags=re.I)
        s = PRIV_IP.sub(FAKE_HOST, s)
        s = LOCAL_NAME.sub(FAKE_HOST, s)
        if self.server_id:
            s = s.replace(self.server_id, FAKE_SERVER_ID)
        for n in self.names:
            s = s.replace(n, "Music Assistant")
        if self.username:
            s = re.sub(r"(?<![A-Za-z0-9_])" + re.escape(self.username) + r"(?![A-Za-z0-9_])", "user", s, flags=re.I)
        return s

    def scrub(self, o, fixture=True):
        if isinstance(o, dict):
            out = {}
            for k, v in o.items():
                if fixture:
                    if k in SECRET_KEYS:
                        out[k] = "<redacted>"
                        continue
                    if k == "server_id" and isinstance(v, str):
                        out[k] = FAKE_SERVER_ID
                        continue
                    if k == "user_id" and isinstance(v, str):
                        out[k] = FAKE_UUID
                        continue
                    if k in ("username", "display_name") and isinstance(v, str):
                        out[k] = "user"
                        continue
                    if k in ("avatar_url", "email"):
                        out[k] = None
                        continue
                    if k == "owner" and isinstance(v, str):
                        out[k] = "user"
                        continue
                    if k == "device_name" and isinstance(v, str):
                        out[k] = "Roadie"
                        continue
                    if k in BULK_EMPTY and isinstance(v, list):
                        out[k] = []
                        continue
                    if k in BULK_TRUNC and isinstance(v, str):
                        out[k] = self.scrub_str(v)[:160]
                        continue
                out[k] = self.scrub(v, fixture)
            return out
        if isinstance(o, list):
            return [self.scrub(v, fixture) for v in o]
        if isinstance(o, str):
            return self.scrub_str(o)
        return o


# ---------------------------------------------------------------- gate

def owned_files(root):
    files = []
    for rel in (FIXTURE_REL, DOCS_REL, SENDSPIN_FIXTURE_REL):
        for dp, _, fns in os.walk(os.path.join(root, rel)):
            for fn in fns:
                files.append(os.path.join(dp, fn))
    notes = os.path.join(root, NOTES_REL)
    if os.path.exists(notes):
        files.append(notes)
    return files


def gate(files, targets, fixtures_dirs):
    """Return a list of (file, rule) problems. Never prints matched content."""
    problems = []
    needles = [("token", targets.token), ("token(urlencoded)", urllib.parse.quote(targets.token, safe=""))]
    if targets.server_id:
        needles.append(("server_id", targets.server_id))
    for h in targets.hosts:
        needles.append(("host", h))
    for n in targets.names:
        needles.append(("server name", n))
    for path in files:
        try:
            with open(path, encoding="utf-8", errors="replace") as f:
                text = f.read()
        except OSError:
            problems.append((path, "unreadable"))
            continue
        low = text.lower()
        for rule, n in needles:
            if n and n.lower() in low:
                problems.append((path, rule))
        if PRIV_IP.search(text):
            problems.append((path, "private IPv4"))
        if LOCAL_NAME.search(text):
            problems.append((path, ".local name"))
        for sub in ("X-Plex-Token", "token=", "Bearer "):
            if sub in text:
                problems.append((path, "substring " + sub.strip()))
        if targets.username and any(path.startswith(d) for d in fixtures_dirs):
            if re.search(r"(?<![A-Za-z0-9_])" + re.escape(targets.username) + r"(?![A-Za-z0-9_])", text, re.I):
                problems.append((path, "user name"))
    return problems


# ---------------------------------------------------------------- recording

def dns_sd(args, seconds=5):
    import pty
    master, slave = pty.openpty()
    try:
        p = subprocess.Popen(["dns-sd"] + args, stdout=slave, stderr=slave, stdin=subprocess.DEVNULL)
    except OSError as e:
        os.close(master)
        os.close(slave)
        return "dns-sd unavailable: %s\n" % e
    os.close(slave)
    out = b""
    end = time.time() + seconds
    while time.time() < end:
        r, _, _ = select.select([master], [], [], 0.2)
        if r:
            try:
                d = os.read(master, 4096)
            except OSError:
                break
            if not d:
                break
            out += d
    p.terminate()
    try:
        p.wait(timeout=2)
    except subprocess.TimeoutExpired:
        p.kill()
    os.close(master)
    return out.decode("utf-8", "replace").replace("\r\n", "\n").replace("\r", "")


def find_urls(o, needle, acc):
    if isinstance(o, dict):
        for v in o.values():
            find_urls(v, needle, acc)
    elif isinstance(o, list):
        for v in o:
            find_urls(v, needle, acc)
    elif isinstance(o, str) and needle in o and o.startswith("http"):
        acc.append(o)


def find_images(o, acc):
    if isinstance(o, dict):
        if "path" in o and "provider" in o and "type" in o:
            acc.append(o)
        for v in o.values():
            find_images(v, acc)
    elif isinstance(o, list):
        for v in o:
            find_images(v, acc)


def write_fixtures(fixtures, targets, fix_dir, summary):
    """Scrub, truncate and write call fixtures; returns the written paths."""
    written = []
    for name, obj in fixtures.items():
        o = targets.scrub(obj, fixture=True)
        keep = TRUNCATE.get(name, 3 if name.startswith("recommendations-items-") else None)
        if keep is not None and isinstance(o, dict):
            for fr in o.get("frames", []):
                if isinstance(fr.get("result"), list) and len(fr["result"]) > keep:
                    o.setdefault("original_item_counts", []).append(len(fr["result"]))
                    fr["result"] = fr["result"][:keep]
                    o["truncated_to_%d_items_per_frame" % keep] = True
        p = os.path.join(fix_dir, name + ".json")
        data = json.dumps(o, indent=2, ensure_ascii=False) + "\n"
        with open(p, "w", encoding="utf-8") as f:
            f.write(data)
        written.append(p)
        n = len(o.get("frames", o.get("events", []))) if isinstance(o, dict) else 1
        summary.append((name + ".json", n, len(data)))
    return written


def answered(rc):
    """True when a recorded call got a reply that is not an error frame. Session.call never raises on
    an error frame or a timeout (it returns no frames), so cleanup steps check this."""
    return bool(rc.get("frames")) and not is_error(rc)


def failure_reason(rc):
    return "error frame" if rc.get("frames") else "no reply before the timeout"


def run_playlist_writes(s, tracks, name, fixtures, scrub=str, report=print, sleep=time.sleep):
    """The writes run's steps and cleanup, separate from I/O setup so scripts/tests can drive it with a
    fake Session. Returns a failure description or None. Cleanup always runs; any doubt about server
    state is printed as CLEANUP FAILED; an interrupt (KeyboardInterrupt, SystemExit) during cleanup is
    reported and then re-raised after the remaining cleanup steps."""
    st = {"playlist_id": None, "create_sent": False, "fav_added": False, "fav_removed": False}
    t0 = tracks[0]
    track_name = t0.get("name") or t0.get("uri")
    failed = None

    def R(fname, command, a=None, timeout=15):
        rc = s.call(command, a, timeout=timeout)
        fixtures[fname] = rc
        if is_error(rc) and fname != "error-unknown-command-move":
            report("note: %s answered with an error frame" % fname)
        return rc

    try:
        st["create_sent"] = True
        pl = result_of(R("playlist-create", "music/playlists/create_playlist", {"name": name}))
        if not isinstance(pl, dict) or pl.get("name") != name or not pl.get("item_id"):
            raise RuntimeError("create_playlist did not return the new playlist")
        st["playlist_id"] = playlist_id = pl["item_id"]
        ref = {"item_id": playlist_id, "provider_instance_id_or_domain": "library"}
        R("playlist-add-tracks", "music/playlists/add_playlist_tracks",
          {"db_playlist_id": playlist_id, "uris": [t["uri"] for t in tracks[:2]]})
        sleep(3)  # the add is a background task
        R("playlist-tracks-after-add", "music/playlists/playlist_tracks", ref, timeout=30)
        R("playlist-remove-tracks", "music/playlists/remove_playlist_tracks",
          {"db_playlist_id": playlist_id, "positions_to_remove": [1]})
        sleep(3)
        R("playlist-tracks-after-remove", "music/playlists/playlist_tracks", ref, timeout=30)
        cur = result_of(s.call("music/playlists/get", ref)) or pl
        renamed = dict(cur, name=name + " renamed")
        R("playlist-update", "music/playlists/update",
          {"item_id": playlist_id, "update": renamed, "overwrite": True})
        R("error-unknown-command-move", "music/playlists/move_playlist_track",
          {"db_playlist_id": playlist_id, "from_position": 1, "to_position": 1})
        if t0.get("favorite"):
            report("note: the first track is already a favorite; favorite-add/remove skipped")
        else:
            st["fav_added"] = True  # until the server says otherwise: a timeout may still have added it
            if is_error(R("favorite-add", "music/favorites/add_item", {"item": t0["uri"]})):
                st["fav_added"] = False
            else:
                rc = R("favorite-remove", "music/favorites/remove_item",
                       {"media_type": "track", "library_item_id": t0["item_id"]})
                st["fav_removed"] = answered(rc)
    except Exception as e:  # recorded; cleanup still runs
        failed = type(e).__name__ + ": " + scrub(str(e))
    finally:
        cleanup_playlist_writes(s, R, st, name, track_name, t0, report)
    return failed


def cleanup_playlist_writes(s, R, st, name, track_name, t0, report=print):
    interrupt = None
    if st["fav_added"] and not st["fav_removed"]:
        reason = None
        try:
            rc = s.call("music/favorites/remove_item",
                        {"media_type": "track", "library_item_id": t0["item_id"]}, timeout=15)
            if answered(rc):
                st["fav_removed"] = True
            else:
                reason = failure_reason(rc)
        except BaseException as e:
            reason = type(e).__name__
            if not isinstance(e, Exception):
                interrupt = e
        if reason:
            report("CLEANUP FAILED (%s): un-favorite the track %r in the Music Assistant UI" % (reason, track_name))
    if st["playlist_id"] is not None:
        reason = None
        try:
            rc = R("playlist-delete", "music/library/remove_item",
                   {"media_type": "playlist", "library_item_id": st["playlist_id"]})
            if not answered(rc):
                reason = failure_reason(rc)
        except BaseException as e:
            reason = type(e).__name__
            if not isinstance(e, Exception):
                interrupt = interrupt or e
        if reason:
            report("CLEANUP FAILED (%s): delete the playlist named %r in the Music Assistant UI" % (reason, name))
    elif st["create_sent"]:
        report("CLEANUP FAILED: the playlist named %r may exist; delete it in the Music Assistant UI" % name)
    if interrupt is not None:
        raise interrupt


def record_playlist_writes(args):
    """#0133, playlists design §1.5 step 2. Opt-in, self-cleaning: every write targets a playlist this
    run creates and deletes in `finally`; a favorite is added and removed only when the track was not one."""
    base, token = read_env()
    out_root = os.path.abspath(args["out"]) if args["out"] else None
    run_id = time.strftime("%Y%m%d-%H%M%S")
    fix_dir = os.path.join(out_root, "Fixtures") if out_root else os.path.join(ROOT, FIXTURE_REL)
    tr_dir = os.path.join(out_root, "transcript") if out_root else os.path.join(ROOT, "build", "ma-recorder", run_id + "-writes")
    os.makedirs(tr_dir, exist_ok=True)
    os.makedirs(fix_dir, exist_ok=True)
    transcript = open(os.path.join(tr_dir, "transcript.jsonl"), "w", encoding="utf-8")

    st, _, body = http_get(base, "/info")
    if st != 200:
        die("GET /info returned %d" % st)
    targets = Targets(base, token, json.loads(body))
    s = Session(base, transcript, token, allowed=ALLOWED | ALLOWED_WRITES)
    s.first_frame()
    res = result_of(s.call("auth", {"token": token}))
    if not (isinstance(res, dict) and res.get("authenticated")):
        s.ws.close()
        die("authentication did not succeed; stopping before sending anything else")
    user = res.get("user") or {}
    if isinstance(user.get("username"), str):
        targets.username = user["username"]
    start = time.time()
    s.events = []
    fixtures = {}

    tracks = result_of(s.call("music/tracks/library_items", {"limit": 2, "offset": 0, "order_by": "sort_name"})) or []
    tracks = [t for t in tracks if isinstance(t, dict) and t.get("uri")]
    if len(tracks) < 2:
        s.ws.close()
        die("the library needs at least two tracks")
    name = "Roadie fixture " + run_id
    failed = None
    try:
        failed = run_playlist_writes(s, tracks, name, fixtures, scrub=targets.scrub_str)
    finally:
        # Let the trailing media_item_* events arrive.
        end = time.time() + 5
        while time.time() < end:
            try:
                t = s.ws.recv(min(1.0, end - time.time()))
            except Closed:
                break
            if t:
                s.events.append((time.time(), json.loads(t)))
        s.ws.close()
        transcript.close()
    events = [{"after_ms": int((t - start) * 1000), "frame": f} for t, f in s.events][:80]
    fixtures["events-playlists"] = {"events": events, "capped": len(s.events) > 80,
                                    "server_pings_seen": s.ws.pings, "closed_by_server": None}
    summary = []
    written = write_fixtures(fixtures, targets, fix_dir, summary)
    for fname, frames, size in summary:
        print("%-34s frames=%-3d bytes=%d" % (fname, frames, size))
    problems = gate(written, targets, [fix_dir])
    if problems:
        for p in written:
            os.remove(p)
        print("SECRET GATE FAILED; written files deleted:")
        for path, rule in problems:
            print("  %s: %s" % (os.path.relpath(path, ROOT), rule))
        sys.exit(2)
    print("secret gate: passed (%d files)" % len(written))
    print("run id: %s ; transcript: %s" % (run_id, os.path.relpath(tr_dir, ROOT)))
    if failed:
        die("a step failed (%s); see any CLEANUP FAILED line above" % failed)


def record(args):
    base, token = read_env()
    out_root = os.path.abspath(args["out"]) if args["out"] else None
    run_id = time.strftime("%Y%m%d-%H%M%S")
    if out_root:
        fix_dir = os.path.join(out_root, "Fixtures")
        docs_dir = os.path.join(out_root, "docs-ma-protocol")
        tr_dir = os.path.join(out_root, "transcript")
    else:
        fix_dir = os.path.join(ROOT, FIXTURE_REL)
        docs_dir = os.path.join(ROOT, DOCS_REL)
        tr_dir = os.path.join(ROOT, "build", "ma-recorder", run_id)
    os.makedirs(tr_dir, exist_ok=True)
    transcript = open(os.path.join(tr_dir, "transcript.jsonl"), "w", encoding="utf-8")

    fixtures = {}   # name -> object (raw until scrubbed)
    docs = {}       # name -> object or text
    summary = []

    # 1. /info
    st, _, body = http_get(base, "/info")
    if st != 200:
        die("GET /info returned %d" % st)
    info = json.loads(body)
    targets = Targets(base, token, info)
    fixtures["info-http"] = info

    # 2. command list and OpenAPI
    for name in ("commands", "openapi"):
        st, _, body = http_get(base, "/api-docs/%s.json" % name)
        if st == 200:
            docs[name + ".json"] = json.loads(body)
        else:
            print("note: /api-docs/%s.json returned %d" % (name, st))

    # 3. connection A: no auth
    s = Session(base, transcript, token)
    fixtures["server-info"] = {"frames": [s.first_frame()]}
    fixtures["time"] = s.call("time")
    fixtures["error-unauthenticated"] = s.call("players/all")
    s.ws.close()

    # 4. connection B: wrong token
    s = Session(base, transcript, token)
    s.first_frame()
    fixtures["error-auth"] = s.call("auth", {"token": "not-a-real-token"})
    s.ws.close()

    # 5. connection C: real token
    s = Session(base, transcript, token)
    s.first_frame()
    rec = s.call("auth", {"token": token})
    # The recorded request must not carry the real token.
    rec["args"] = {"token": "<redacted>"}
    fixtures["auth-ok"] = rec
    res = result_of(rec)
    if not (isinstance(res, dict) and res.get("authenticated")):
        s.ws.close()
        die("authentication did not succeed; stopping before sending anything else")
    user = (res.get("user") or {}) if isinstance(res, dict) else {}
    if isinstance(user.get("username"), str):
        targets.username = user["username"]

    def R(name, command, a=None, timeout=10, probe=False):
        rc = s.call(command, a, timeout=timeout, probe=probe)
        fixtures[name] = rc
        return result_of(rc)

    R("auth-me", "auth/me")
    R("info-ws", "info")
    R("providers", "providers", {"provider_type": "music"})
    players = R("players-all", "players/all") or []
    R("players-all-unavailable", "players/all", {"return_unavailable": True, "return_disabled": True})
    pid = players[0].get("player_id") if players and isinstance(players, list) else None
    if pid:
        R("player-get", "players/get", {"player_id": pid})
    R("error-unknown-player", "players/get", {"player_id": "roadie-no-such-player"})
    R("error-unknown-command", "roadie/no_such_command", {}, probe=True)

    queues = R("player-queues-all", "player_queues/all") or []
    qid = queues[0].get("queue_id") if queues and isinstance(queues, list) else pid
    if qid:
        R("player-queue-get", "player_queues/get", {"queue_id": qid})
        R("player-queue-items", "player_queues/items", {"queue_id": qid, "limit": 3, "offset": 0})
    if pid:
        R("player-queue-active", "player_queues/get_active_queue", {"player_id": pid})

    first = {}
    for kind, extra in (("artists", {"album_artists_only": True}), ("albums", {}), ("tracks", {}), ("playlists", {})):
        total = R(kind + "-count", "music/%s/count" % kind)
        page_args = dict(limit=3, offset=0, order_by="sort_name")
        page_args.update(extra)
        items = R(kind + "-page", "music/%s/library_items" % kind, page_args) or []
        first[kind] = items[0] if isinstance(items, list) and items else None
        if kind == "playlists":
            continue
        n = total if isinstance(total, int) else (total.get("count") if isinstance(total, dict) else None)
        if isinstance(n, int) and n > 0:
            la = dict(limit=3, offset=n - 1, order_by="sort_name")
            la.update(extra)
            R(kind + "-last-page", "music/%s/library_items" % kind, la)
        fa = dict(limit=1, offset=0, order_by="sort_name", summary=False)
        fa.update(extra)
        R(kind + "-page-full", "music/%s/library_items" % kind, fa)

    def key(item):
        return item.get("item_id"), item.get("uri")

    if first.get("artists"):
        R("artist-albums", "music/artists/artist_albums",
          {"item_id": first["artists"]["item_id"], "provider_instance_id_or_domain": "library"})
    album = first.get("albums")
    album_full = None
    if album:
        R("album-tracks", "music/albums/album_tracks",
          {"item_id": album["item_id"], "provider_instance_id_or_domain": "library", "in_library_only": True})
        album_full = R("album-get", "music/albums/get",
                       {"item_id": album["item_id"], "provider_instance_id_or_domain": "library"})
        if album.get("uri"):
            R("item-by-uri", "music/item_by_uri", {"uri": album["uri"]})
    if first.get("playlists"):
        pl = first["playlists"]
        R("playlist-tracks", "music/playlists/playlist_tracks",
          {"item_id": pl["item_id"], "provider_instance_id_or_domain": "library"}, timeout=30)
    # #0133 (playlists design §1.5): playlist, favorites, Discover, radio and queue reads.
    if first.get("playlists"):
        pl = first["playlists"]
        R("playlist-get", "music/playlists/get",
          {"item_id": pl["item_id"], "provider_instance_id_or_domain": "library"})
    R("playlists-favorites-page", "music/playlists/library_items",
      {"limit": 3, "offset": 0, "order_by": "sort_name", "favorite": True})
    R("tracks-favorites-page", "music/tracks/library_items",
      {"limit": 3, "offset": 0, "order_by": "sort_name", "favorite": True})
    rows = R("recommendations", "music/recommendations", timeout=30) or []
    for row in rows if isinstance(rows, list) else []:
        rid = row.get("item_id") if isinstance(row, dict) else None
        if not isinstance(rid, str) or not rid:
            continue
        safe = re.sub(r"[^A-Za-z0-9_-]+", "_", rid)[:60]
        R("recommendations-items-" + safe, "music/recommendations/items",
          {"provider": row.get("provider"), "item_id": rid}, timeout=30)
    R("recently-played-items", "music/recently_played_items", {"limit": 5})
    R("recently-added-tracks", "music/recently_added_tracks", {"limit": 3})
    R("radios-count", "music/radios/count")
    R("radios-page", "music/radios/library_items", {"limit": 3, "offset": 0, "order_by": "sort_name"})
    # First editable playlist: an unsaved listing (one read), then the export of that one.
    scan = result_of(s.call("music/playlists/library_items", {"limit": 50, "offset": 0, "order_by": "sort_name"})) or []
    editable = next((p for p in scan if isinstance(p, dict) and p.get("is_editable")), None)
    if editable:
        R("playlist-export", "music/playlists/export_playlist", {"db_playlist_id": editable["item_id"]}, timeout=30)
    loaded = next((q for q in queues if isinstance(q, dict) and isinstance(q.get("items"), int) and q["items"] > 0), None) \
        if isinstance(queues, list) else None
    # A --record-queue recording (#0196) of this fixture is fuller; keep it.
    if loaded and not os.path.exists(os.path.join(fix_dir, "player-queue-items-loaded.json")):
        R("player-queue-items-loaded", "player_queues/items", {"queue_id": loaded["queue_id"], "limit": 5, "offset": 0})

    trk = first.get("tracks")
    if trk and isinstance(trk.get("name"), str) and trk["name"].split():
        R("search", "music/search", {"search_query": trk["name"].split()[0],
                                      "media_types": ["artist", "album", "track", "playlist"],
                                      "limit": 3, "providers": ["library"]})

    # 6. artwork probe
    probes = []
    imgs = []
    for k in list(fixtures):
        if isinstance(fixtures[k], dict) and "frames" in fixtures[k] and k not in ("artwork-probe",):
            find_images(result_of(fixtures[k]), imgs)
    urls = []
    for k in ("players-all", "player-queue-items", "player-queue-get", "album-get", "tracks-page-full", "albums-page-full"):
        if k in fixtures:
            find_urls(result_of(fixtures[k]), "imageproxy", urls)
    cands = []
    if imgs:
        im = imgs[0]
        cands.append(("path+provider", "/imageproxy?path=%s&provider=%s&size=200" % (
            urllib.parse.quote(str(im.get("path")), safe=""), urllib.parse.quote(str(im.get("provider")), safe=""))))
        if im.get("proxy_id"):
            pid_q = urllib.parse.quote(str(im["proxy_id"]), safe="")
            cands.append(("proxy_id", "/imageproxy/%s?size=200" % pid_q))
            cands.append(("proxy_id+fmt", "/imageproxy/%s?size=200&fmt=jpg" % pid_q))
            cands.append(("proxy_id size=256", "/imageproxy/%s?size=256" % pid_q))
            cands.append(("proxy_id size=256+fmt", "/imageproxy/%s?size=256&fmt=jpg" % pid_q))
    for u in urls[:1]:
        cands.append(("server-url", u))
    for label, c in cands:
        for authed in (True, False):
            try:
                stt, ct, bd = http_get(base, c, bearer=token if authed else None)
            except Exception as e:  # network error: record and move on
                stt, ct, bd = -1, type(e).__name__, b""
            pr = {"form": label, "candidate": c, "authorized": authed, "status": stt,
                  "content_type": ct, "bytes": len(bd)}
            if not ct.startswith("image/") and bd:
                pr["body_text"] = bd[:200].decode("utf-8", "replace")
            probes.append(pr)
    fixtures["artwork-probe"] = {"image_fields": imgs[:1], "probes": probes}

    # 7. event window
    secs = args["events_seconds"]
    print("Now, from the MA web UI, pause and resume a speaker that is already playing, or skip a track, "
          "to capture player/queue events; the recorder itself never sends a transport command. (%ds)" % secs)
    sys.stdout.flush()
    start = time.time()
    events = [{"after_ms": int((t - start) * 1000), "frame": f} for t, f in s.events][:40]
    end = start + secs
    closed = None
    while time.time() < end and len(events) < 40:
        try:
            t = s.ws.recv(min(1.0, end - time.time()))
        except Closed as e:
            closed = str(e)
            break
        if t:
            events.append({"after_ms": int((time.time() - start) * 1000), "frame": json.loads(t)})
    fixtures["events"] = {"events": events[:40], "capped": len(events) >= 40,
                          "server_pings_seen": s.ws.pings, "closed_by_server": closed}
    s.ws.close()
    transcript.close()

    # 9. Bonjour
    d1 = dns_sd(["-B", "_music-assistant._tcp"])
    d2 = dns_sd(["-B", "_services._dns-sd._udp"])
    docs["dns-sd.txt"] = "$ dns-sd -B _music-assistant._tcp  (5 s)\n" + d1 + "\n$ dns-sd -B _services._dns-sd._udp  (5 s)\n" + d2
    m = re.search(r"_music-assistant\._tcp\.\s+(.+)$", d1, re.M)
    if m:
        d3 = dns_sd(["-L", m.group(1).strip(), "_music-assistant._tcp"])
        docs["dns-sd.txt"] += "\n$ dns-sd -L <instance> _music-assistant._tcp  (5 s)\n" + d3

    # 10. scrub, write, gate
    # The writes run's fixtures (#0133) survive a default run; everything else is rewritten.
    if os.path.isdir(fix_dir):
        for fn in os.listdir(fix_dir):
            if fn.endswith(".json") and fn[:-5] not in WRITE_FIXTURES | QUEUE_FIXTURES:
                os.remove(os.path.join(fix_dir, fn))
    os.makedirs(fix_dir, exist_ok=True)
    os.makedirs(docs_dir, exist_ok=True)
    written = write_fixtures(fixtures, targets, fix_dir, summary)
    for name, obj in docs.items():
        p = os.path.join(docs_dir, name)
        if isinstance(obj, str):
            txt = re.sub(r"\blocal\.", "<domain>", obj)
            txt = targets.scrub_str(txt)
            lines = []
            for ln in txt.split("\n"):
                if "_music-assistant._tcp" in ln and re.match(r"^\S+\s+(Add|Rmv)", ln):
                    ln = re.sub(r"(_music-assistant\._tcp\.\s+).*$", r"\1<instance>", ln)
                lines.append(ln)
            data = "\n".join(lines)
        else:
            data = json.dumps(targets.scrub(obj, fixture=False), indent=1, ensure_ascii=False) + "\n"
        with open(p, "w", encoding="utf-8") as f:
            f.write(data)
        written.append(p)
        summary.append((name, 1, len(data)))
    for name, frames, size in summary:
        print("%-34s frames=%-3d bytes=%d" % (name, frames, size))
    problems = gate(written, targets, [fix_dir])
    if problems:
        for p in written:
            os.remove(p)
        print("SECRET GATE FAILED; written files deleted:")
        for path, rule in problems:
            print("  %s: %s" % (os.path.relpath(path, ROOT), rule))
        sys.exit(2)
    print("secret gate: passed (%d files)" % len(written))
    print("run id: %s ; transcript: %s" % (run_id, os.path.relpath(tr_dir, ROOT)))


def pick_loaded_queue(queues, queue_id=None):
    """The named queue, else the playing one with items; None when no queue has items (#0196)."""
    qs = [q for q in (queues if isinstance(queues, list) else []) if isinstance(q, dict)]
    if queue_id:
        qs = [q for q in qs if q.get("queue_id") == queue_id]
    loaded = [q for q in qs if isinstance(q.get("items"), int) and q["items"] > 0]
    return next((q for q in loaded if q.get("state") == "playing"), loaded[0] if loaded else None)


def record_queue_calls(s, queue_id=None):
    """#0196: the read-only calls of --record-queue on session `s`; returns the fixtures (unscrubbed). Dies when
    no queue has items."""
    fixtures = {}

    def R(name, command, a=None, timeout=10):
        rc = s.call(command, a, timeout=timeout)
        if name:
            fixtures[name] = rc
        return result_of(rc)

    R("players-all-playing", "players/all")
    queues = R(None, "player_queues/all") or []
    q = pick_loaded_queue(queues, queue_id)
    if q is None:
        die("no queue has items; load and play a queue first")
    qid = q["queue_id"]
    R(None, "player_queues/get_active_queue", {"player_id": qid})
    R("player-queue-get-loaded", "player_queues/get", {"queue_id": qid})
    R("player-queue-items-loaded", "player_queues/items", {"queue_id": qid, "limit": QUEUE_PAGE, "offset": 0}, timeout=30)
    R("player-queue-items-page2", "player_queues/items",
      {"queue_id": qid, "limit": QUEUE_PAGE, "offset": QUEUE_PAGE}, timeout=30)
    return fixtures


def record_queue(args):
    """#0196: records a loaded, playing queue. Read-only (ALLOWED); writes only QUEUE_FIXTURES."""
    base, token = read_env()
    out_root = os.path.abspath(args["out"]) if args["out"] else None
    run_id = time.strftime("%Y%m%d-%H%M%S")
    fix_dir = os.path.join(out_root, "Fixtures") if out_root else os.path.join(ROOT, FIXTURE_REL)
    tr_dir = os.path.join(out_root, "transcript") if out_root else os.path.join(ROOT, "build", "ma-recorder", run_id + "-queue")
    os.makedirs(tr_dir, exist_ok=True)
    os.makedirs(fix_dir, exist_ok=True)
    transcript = open(os.path.join(tr_dir, "transcript.jsonl"), "w", encoding="utf-8")
    st, _, body = http_get(base, "/info")
    if st != 200:
        die("GET /info returned %d" % st)
    targets = Targets(base, token, json.loads(body))
    s = Session(base, transcript, token, allowed=ALLOWED)
    s.first_frame()
    res = result_of(s.call("auth", {"token": token}))
    if not (isinstance(res, dict) and res.get("authenticated")):
        s.ws.close()
        die("authentication did not succeed; stopping before sending anything else")
    user = res.get("user") or {}
    if isinstance(user.get("username"), str):
        targets.username = user["username"]
    try:
        fixtures = record_queue_calls(s, args.get("queue_id"))
        secs = args["events_seconds"]
        print("Recording queue events while the queue plays (%ds); the recorder sends no transport command." % secs)
        sys.stdout.flush()
        start = time.time()
        s.events = []
        events = []
        closed = None
        while time.time() < start + secs and len(events) < 80:
            try:
                t = s.ws.recv(min(1.0, start + secs - time.time()))
            except Closed as e:
                closed = str(e)
                break
            if t:
                f = json.loads(t)
                if isinstance(f, dict) and f.get("event") in ("queue_updated", "queue_items_updated", "player_updated"):
                    events.append({"after_ms": int((time.time() - start) * 1000), "frame": f})
        fixtures["events-queue"] = {"events": events, "capped": len(events) >= 80,
                                    "server_pings_seen": s.ws.pings, "closed_by_server": closed}
    finally:
        s.ws.close()
        transcript.close()
    summary = []
    written = write_fixtures(fixtures, targets, fix_dir, summary)
    for fname, frames, size in summary:
        print("%-34s frames=%-3d bytes=%d" % (fname, frames, size))
    problems = gate(written, targets, [fix_dir])
    if problems:
        for p in written:
            os.remove(p)
        print("SECRET GATE FAILED; written files deleted:")
        for path, rule in problems:
            print("  %s: %s" % (os.path.relpath(path, ROOT), rule))
        sys.exit(2)
    print("secret gate: passed (%d files)" % len(written))
    print("run id: %s ; transcript: %s" % (run_id, os.path.relpath(tr_dir, ROOT)))


def shape_problems(root):
    """#0133: each fixture parses; call fixtures have command+frames; the writes run touched only its playlist."""
    problems = []
    d = os.path.join(root, FIXTURE_REL)
    if not os.path.isdir(d):
        return problems
    for fn in sorted(os.listdir(d)):
        if not fn.endswith(".json"):
            continue
        path = os.path.join(d, fn)
        try:
            with open(path, encoding="utf-8") as f:
                o = json.load(f)
        except (OSError, ValueError):
            problems.append((path, "not JSON"))
            continue
        stem = fn[:-5]
        if stem in WRITE_FIXTURES and stem != "events-playlists":
            if not (isinstance(o, dict) and o.get("command") in ALLOWED_WRITES | ALLOWED and "frames" in o):
                problems.append((path, "writes fixture without an allowlisted command"))
            elif o["command"] in ALLOWED_WRITES and o["command"] != "music/favorites/add_item" \
                    and o["command"] != "music/favorites/remove_item" and o["command"] != "music/playlists/create_playlist":
                pid = o["args"].get("db_playlist_id", o["args"].get("item_id", o["args"].get("library_item_id")))
                if pid is None:
                    problems.append((path, "writes fixture without a playlist id"))
        if stem in QUEUE_FIXTURES and stem != "events-queue":
            if not (isinstance(o, dict) and o.get("command") in ALLOWED and "args" in o and "frames" in o):
                problems.append((path, "queue fixture without an allowlisted command, args and frames"))
        if stem == "events-queue" and not (isinstance(o, dict) and isinstance(o.get("events"), list)):
            problems.append((path, "events fixture without events"))
        if stem == "events-playlists" and not (isinstance(o, dict) and isinstance(o.get("events"), list)):
            problems.append((path, "events fixture without events"))
    return problems


def check():
    base, token = read_env()
    st, _, body = http_get(base, "/info")
    if st != 200:
        die("GET /info returned %d" % st)
    targets = Targets(base, token, json.loads(body))
    files = owned_files(ROOT)
    if not files:
        die("nothing to check")
    problems = gate(files, targets, [os.path.join(ROOT, FIXTURE_REL)]) + shape_problems(ROOT)
    if problems:
        print("SECRET GATE FAILED:")
        for path, rule in problems:
            print("  %s: %s" % (os.path.relpath(path, ROOT), rule))
        sys.exit(2)
    print("secret gate: passed (%d files)" % len(files))


# ---------------------------------------------------------------- --check-live (#0061)

class NullLog:
    def write(self, _text):
        pass

    def flush(self):
        pass


class LiveReport:
    """One `live: <check> ok|FAIL (<reason>)` line per check. Reasons carry key names and counts, never values."""

    def __init__(self):
        self.total = 0
        self.failed = 0

    def ok(self, name, note=""):
        self.total += 1
        print("live: %s ok%s" % (name, (" (" + note + ")") if note else ""))

    def fail(self, name, reason):
        self.total += 1
        self.failed += 1
        print("live: %s FAIL (%s)" % (name, reason))


def load_fixture(name):
    with open(os.path.join(ROOT, FIXTURE_REL, name + ".json"), encoding="utf-8") as f:
        return json.load(f)


def first_item(result):
    if isinstance(result, list):
        return result[0] if result else None
    return result


def key_diff(fixture_name, live_result):
    """(missing key names, count of extra live keys) of the live reply's first item against the fixture's."""
    fx = load_fixture(fixture_name)
    want = first_item(result_of(fx))
    got = first_item(live_result)
    if not isinstance(want, dict):
        return None, 0
    if not isinstance(got, dict):
        return sorted(want.keys()), 0
    return sorted(set(want) - set(got)), len(set(got) - set(want))


def live_result(rec):
    """The combined result of a recorded call, or raise on an error frame."""
    if not rec["frames"]:
        raise RuntimeError("no reply")
    if is_error(rec):
        raise RuntimeError("error frame %s" % rec["frames"][-1].get("error_code"))
    return result_of(rec)


def check_live():
    base, token = read_env()
    rep = LiveReport()
    log = NullLog()
    session_a = session_b = None
    try:
        # 1. info-http
        info = None
        try:
            st, ctype, body = http_get(base, "/info")
            info = json.loads(body) if st == 200 else None
            want_keys = set(load_fixture("info-http").keys())
            if st != 200:
                rep.fail("info-http", "GET /info returned %d" % st)
            elif not isinstance(info, dict) or want_keys - set(info):
                rep.fail("info-http", "missing keys: " + ", ".join(sorted(want_keys - set(info or {}))))
            elif not isinstance(info.get("schema_version"), int) or info["schema_version"] < 28:
                rep.fail("info-http", "schema_version below 28")
            elif info["schema_version"] != 65:
                rep.ok("info-http", "schema %d; models recorded against 65" % info["schema_version"])
            else:
                rep.ok("info-http")
        except Exception as e:
            rep.fail("info-http", type(e).__name__)

        # 2. handshake, 3. unauthenticated (socket A, never authenticated)
        try:
            session_a = Session(base, log, token)
            first = session_a.first_frame()
            if not isinstance(first, dict) or "message_id" in first or "command" in first:
                rep.fail("handshake", "first frame is not bare server info")
            elif info is not None and set(first) != set(info):
                rep.fail("handshake", "key set differs from /info: missing %s, extra %d" % (
                    ", ".join(sorted(set(info) - set(first))) or "none", len(set(first) - set(info))))
            elif info is not None and first.get("server_id") != info.get("server_id"):
                rep.fail("handshake", "server_id differs from /info")
            else:
                rep.ok("handshake")
        except Exception as e:
            rep.fail("handshake", type(e).__name__)
        try:
            rec = session_a.call("players/all")
            code = rec["frames"][0].get("error_code") if rec["frames"] else None
            rec_t = session_a.call("time")
            t = result_of(rec_t)
            if code != 20:
                rep.fail("unauthenticated", "players/all before auth answered code %s" % code)
            elif not isinstance(t, (int, float)) or isinstance(t, bool):
                rep.fail("unauthenticated", "time did not answer a number")
            else:
                rep.ok("unauthenticated")
        except Exception as e:
            rep.fail("unauthenticated", type(e).__name__)
        if session_a:
            session_a.ws.close()

        # 4. auth (fresh socket B)
        authed = False
        try:
            session_b = Session(base, log, token)
            session_b.first_frame()
            rec = session_b.call("auth", {"token": token})
            f = rec["frames"][0] if rec["frames"] else {}
            if f.get("error_code") == 23:
                rep.fail("auth", "token rejected")
            elif "error_code" in f:
                rep.fail("auth", "error code %s" % f.get("error_code"))
            else:
                res = f.get("result")
                user = res.get("user") if isinstance(res, dict) else None
                if not isinstance(res, dict) or res.get("authenticated") is not True:
                    rep.fail("auth", "authenticated is not true")
                elif not isinstance(user, dict) or {"user_id", "username", "role"} - set(user):
                    rep.fail("auth", "user object lacks user_id, username or role")
                else:
                    authed = True
                    rep.ok("auth")
        except Exception as e:
            rep.fail("auth", type(e).__name__)
        if not authed:
            rep.fail("remaining", "skipped: not authenticated")
            return rep

        s = session_b

        def call(cmd, args=None, **kw):
            return s.call(cmd, args, **kw)

        # 5. shapes
        proxy_ids = []
        first_track_word = None
        first_playlist_id = None
        shapes = [
            ("artists-page", "music/artists/library_items", {"limit": 1, "offset": 0, "order_by": "sort_name", "album_artists_only": True}),
            ("albums-page", "music/albums/library_items", {"limit": 1, "offset": 0, "order_by": "sort_name"}),
            ("tracks-page", "music/tracks/library_items", {"limit": 1, "offset": 0, "order_by": "sort_name"}),
            ("playlists-page", "music/playlists/library_items", {"limit": 1, "offset": 0, "order_by": "sort_name"}),
            ("players-all", "players/all", {}),
            ("player-queues-all", "player_queues/all", {}),
        ]
        # use the fixtures' own args for the listings
        for i, (name, cmd, _a) in enumerate(shapes):
            fx = load_fixture(name)
            if cmd.startswith("music/") and "args" in fx:
                a = dict(fx["args"])
                a["limit"] = 1
                a["offset"] = 0
                shapes[i] = (name, cmd, a)
        for name, cmd, a in shapes:
            try:
                res = live_result(call(cmd, a))
                missing, extra = key_diff(name, res)
                if missing:
                    rep.fail("shapes/" + name, "missing keys: " + ", ".join(missing))
                else:
                    rep.ok("shapes/" + name, "%d extra keys" % extra if extra else "")
                if name == "tracks-page" and isinstance(res, list) and res:
                    title = res[0].get("name") or ""
                    words = [w for w in re.split(r"\W+", title) if len(w) > 2]
                    first_track_word = words[0] if words else (title.split() or [None])[0]
                if name == "playlists-page" and isinstance(res, list) and res:
                    first_playlist_id = res[0].get("item_id")
                for item in (res if isinstance(res, list) else []):
                    imgs = ((item.get("metadata") or {}).get("images") or []) if isinstance(item, dict) else []
                    for im in imgs:
                        if isinstance(im, dict) and im.get("proxy_id"):
                            proxy_ids.append(im["proxy_id"])
            except Exception as e:
                rep.fail("shapes/" + name, str(e) if isinstance(e, RuntimeError) else type(e).__name__)
        try:
            a = dict(load_fixture("search").get("args", {}))
            a["search_query"] = first_track_word or a.get("search_query", "a")
            a["providers"] = ["library"]
            res = live_result(call("music/search", a))
            missing, extra = key_diff("search", res)
            if missing:
                rep.fail("shapes/search", "missing keys: " + ", ".join(missing))
            else:
                rep.ok("shapes/search", "%d extra keys" % extra if extra else "")
        except Exception as e:
            rep.fail("shapes/search", str(e) if isinstance(e, RuntimeError) else type(e).__name__)

        # 6. counts, 7. paging
        counts = {}
        try:
            bad = []
            for kind in ("artists", "albums", "tracks", "playlists"):
                a = {"album_artists_only": True} if kind == "artists" else {}
                n = live_result(call("music/%s/count" % kind, a))
                if not isinstance(n, int) or isinstance(n, bool):
                    bad.append(kind)
                counts[kind] = n
            if bad:
                rep.fail("counts", "not an integer: " + ", ".join(bad))
            else:
                rep.ok("counts")
        except Exception as e:
            rep.fail("counts", str(e) if isinstance(e, RuntimeError) else type(e).__name__)
        try:
            n = counts.get("artists")
            if not isinstance(n, int) or n < 1:
                rep.fail("paging", "no artist count")
            else:
                a = {"limit": 3, "offset": n - 1, "order_by": "sort_name", "album_artists_only": True}
                res = live_result(call("music/artists/library_items", a))
                if isinstance(res, list) and len(res) == 1:
                    rep.ok("paging")
                else:
                    rep.fail("paging", "last page has %s items" % (len(res) if isinstance(res, list) else "no"))
        except Exception as e:
            rep.fail("paging", str(e) if isinstance(e, RuntimeError) else type(e).__name__)

        # 8. partial
        try:
            if not first_playlist_id:
                rep.fail("partial", "no playlist to read")
            else:
                rec = call("music/playlists/playlist_tracks",
                           {"item_id": first_playlist_id, "provider_instance_id_or_domain": "library"}, timeout=60)
                fr = rec["frames"]
                flags = [f.get("partial") for f in fr]
                if not fr or flags[-1] is not False:
                    rep.fail("partial", "no final partial:false frame")
                elif any(f is not True for f in flags[:-1]):
                    rep.fail("partial", "a frame before the last is not partial:true")
                elif len(fr) < 2:
                    rep.fail("partial", "no partial:true frame before the final one")
                elif any(not isinstance(f.get("result"), list) for f in fr):
                    rep.fail("partial", "a result is not an array")
                else:
                    rep.ok("partial", "%d frames" % len(fr))
        except Exception as e:
            rep.fail("partial", type(e).__name__)

        # 9. null-result, 10. error-frame
        try:
            rec = call("players/get", {"player_id": "roadie-no-such-player"})
            f = rec["frames"][0] if rec["frames"] else {}
            if "result" in f and f["result"] is None and f.get("partial") is False:
                rep.ok("null-result")
            else:
                rep.fail("null-result", "not a null result with partial:false")
        except Exception as e:
            rep.fail("null-result", type(e).__name__)
        try:
            rec = call("roadie/no_such_command", probe=True)
            f = rec["frames"][0] if rec["frames"] else {}
            if f.get("error_code") == 12 and isinstance(f.get("details"), str):
                rep.ok("error-frame")
            else:
                rep.fail("error-frame", "expected code 12 with string details, got code %s" % f.get("error_code"))
        except Exception as e:
            rep.fail("error-frame", type(e).__name__)

        # 11. artwork (no Authorization header)
        try:
            if not proxy_ids:
                rep.fail("artwork", "no proxy_id seen")
            else:
                pid = proxy_ids[0]
                st256, ct, _b = http_get(base, "/imageproxy/%s?size=256" % pid)
                st200, _ct, _b = http_get(base, "/imageproxy/%s?size=200" % pid)
                if st256 == 200 and ct.startswith("image/") and st200 == 400:
                    rep.ok("artwork")
                else:
                    rep.fail("artwork", "size 256 answered %d (%s), size 200 answered %d" % (st256, "image" if ct.startswith("image/") else "not image", st200))
        except Exception as e:
            rep.fail("artwork", type(e).__name__)

        # 12. ping (informational), 13. close
        try:
            before = s.ws.pings
            deadline = time.time() + 30
            while time.time() < deadline:
                if s.ws.recv(max(0.05, deadline - time.time())) is None:
                    break
            n = s.ws.pings - before
            rep.ok("ping", "%d pings in 30 s" % n)
        except Exception as e:
            rep.fail("ping", type(e).__name__)
        try:
            s.ws._send_frame(8, struct.pack(">H", 1000))
            try:
                s.ws.recv(3)  # the server echoes the close; Closed is the expected end
            except Closed:
                pass
            rep.ok("close")
        except Exception as e:
            rep.fail("close", type(e).__name__)
    finally:
        for sess in (session_a, session_b):
            try:
                if sess:
                    sess.ws.sock.close()
            except Exception:
                pass
    return rep


# ---------------------------------------------------------------- --probe-audio (#0089)

ADTS_RATES = [96000, 88200, 64000, 48000, 44100, 32000, 24000, 22050, 16000, 12000, 11025, 8000, 7350]


def adts_stats(data):
    """(frames, sample_rate, channels, seconds) from ADTS headers; (0, None, None, 0.0) if none found."""
    i, frames, rate, ch, n = 0, 0, None, None, len(data)
    while i + 7 <= n:
        if data[i] != 0xFF or (data[i + 1] & 0xF0) != 0xF0:
            i += 1
            continue
        sfi = (data[i + 2] >> 2) & 0x0F
        c = ((data[i + 2] & 0x01) << 2) | (data[i + 3] >> 6)
        length = ((data[i + 3] & 0x03) << 11) | (data[i + 4] << 3) | (data[i + 5] >> 5)
        if length < 7 or sfi >= len(ADTS_RATES):
            i += 1
            continue
        frames += 1
        rate, ch = ADTS_RATES[sfi], c
        i += length
    return frames, rate, ch, (frames * 1024.0 / rate) if rate else 0.0


def stream_get(base, target, bearer=None, timeout=45, maxbytes=16000000):
    """GET target (path+query) on the configured host; never prints it. Returns a dict of safe facts."""
    b = urllib.parse.urlsplit(base)
    if b.scheme == "https":
        conn = http.client.HTTPSConnection(b.netloc, timeout=timeout, context=TLS)
    else:
        conn = http.client.HTTPConnection(b.netloc, timeout=timeout)
    prefix = b.path.rstrip("/")
    headers = {"Accept": "*/*", "User-Agent": "Roadie-recorder"}
    if bearer:
        headers["Authorization"] = "Bearer " + bearer
    t0 = time.time()
    try:
        conn.request("GET", prefix + target, headers=headers)
        r = conn.getresponse()
        data = bytearray()
        truncated = False
        try:
            data += r.read(maxbytes)
        except http.client.IncompleteRead as e:  # the chunked body can end without a final chunk
            data += e.partial
            truncated = True
        return {"status": r.status, "content_type": r.getheader("Content-Type", ""),
                "content_length": r.getheader("Content-Length") is not None,
                "accept_ranges": r.getheader("Accept-Ranges") is not None,
                "bytes": len(data), "incomplete_end": truncated, "elapsed_s": round(time.time() - t0, 2), "data": bytes(data)}
    finally:
        conn.close()


def probe_audio(write, wait):
    base, token = read_env()
    out = {}

    def line(name, verdict, detail):
        print("probe: %s %s %s" % (name, verdict, detail))

    st, _, body = http_get(base, "/info")
    if st != 200:
        die("GET /info returned %d" % st)
    info = json.loads(body)
    targets = Targets(base, token, info)
    out["info"] = {"server_version": info.get("server_version"), "schema_version": info.get("schema_version")}
    line("info", "info", "server %s schema %s" % (info.get("server_version"), info.get("schema_version")))

    st, _, body = http_get(base, "/api-docs/commands.json", maxbytes=20000000)
    names = []
    if st == 200:
        doc = json.loads(body)
        if isinstance(doc, dict):
            names = list(doc.keys()) if "music/tracks/preview" in doc or not isinstance(doc.get("commands"), list) else []
        if isinstance(doc, list) or (isinstance(doc, dict) and isinstance(doc.get("commands"), list)):
            items = doc if isinstance(doc, list) else doc["commands"]
            names = [c.get("command") for c in items if isinstance(c, dict)]
    names = [n for n in names if isinstance(n, str)]
    hits = sorted(n for n in names if re.search(r"stream|preview|builtin_player|web_player|register", n))
    out["commands"] = {"status": st, "count": len(names), "has_preview": "music/tracks/preview" in names, "matching": hits}
    line("commands", "ok" if names else "FAIL", "status %d, %d commands, preview %s, matching: %s" % (
        st, len(names), "music/tracks/preview" in names, ", ".join(hits) or "none"))

    s = Session(base, NullLog(), token)
    try:
        s.first_frame()
        f = (s.call("auth", {"token": token})["frames"] or [{}])[0]
        if "error_code" in f:
            die("auth failed with code %s" % f.get("error_code"))
        rec = s.call("music/tracks/library_items", {"limit": 20, "offset": 0, "summary": False}, timeout=20)
        tracks = live_result(rec) or []
        track = next((t for t in tracks if isinstance(t, dict) and (t.get("duration") or 0) >= 90), None)
        if not track:
            line("track", "FAIL", "no track of 90 s or more in the first %d" % len(tracks))
            return
        mapping = next(iter(track.get("provider_mappings") or []), {}) or {}
        fmt = (mapping.get("audio_format") or {}).get("content_type")
        duration = track.get("duration")
        out["track"] = {"duration": duration, "provider_domain": mapping.get("provider_domain"), "content_type": fmt}
        line("track", "ok", "duration %ss, provider %s, format %s" % (duration, mapping.get("provider_domain"), fmt))

        previews = []
        for label, args in (("a-library", {"provider_instance_id_or_domain": "library", "item_id": str(track.get("item_id"))}),
                            ("b-mapping", {"provider_instance_id_or_domain": mapping.get("provider_instance"),
                                           "item_id": mapping.get("item_id")})):
            rec = s.call("music/tracks/preview", args, timeout=20)
            fr = rec["frames"][-1] if rec["frames"] else {}
            if not rec["frames"] or "error_code" in fr:
                out["preview-cmd-" + label] = {"error_code": fr.get("error_code")}
                line("preview-cmd-" + label, "FAIL", "error_code %s" % fr.get("error_code"))
                continue
            url = result_of(rec)
            if not isinstance(url, str):
                line("preview-cmd-" + label, "FAIL", "result is %s" % type(url).__name__)
                continue
            u = urllib.parse.urlsplit(url)
            port = u.port or (443 if u.scheme == "https" else 80)
            qnames = sorted(set(k for k, _ in urllib.parse.parse_qsl(u.query, keep_blank_values=True)))
            same = u.hostname in targets.hosts
            relative = not u.scheme and not u.netloc
            facts = {"scheme": u.scheme or "(relative)", "same_host": same or relative,
                     "port": "(api server)" if relative else (port if port in (8095, 8097) else "other"),
                     "path": u.path if u.path == "/preview" or same or relative else "(external)",
                     "query_params": qnames}
            out["preview-cmd-" + label] = facts
            line("preview-cmd-" + label, "ok", "scheme %s, same host %s, port %s, path %s, params %s" % (
                facts["scheme"], facts["same_host"], facts["port"], facts["path"], ",".join(qnames) or "none"))
            previews.append((label, u, qnames, same))
    finally:
        s.ws.close()

    for label, u, qnames, same in previews[:1]:
        target = urllib.parse.urlunsplit(("", "", u.path or "/", u.query, ""))
        verdicts = []
        for auth_label, bearer in (("no-auth", None), ("bearer", token)):
            r = stream_get(base, target, bearer=bearer)
            frames, rate, ch, secs = adts_stats(r.pop("data"))
            if r["status"] != 200 or not frames:
                verdict = "none"
            elif duration and abs(secs - duration) <= 2:
                verdict = "full"
            elif 25 <= secs <= 35:
                verdict = "preview"
            else:
                verdict = "other"
            r.update({"adts_frames": frames, "sample_rate": rate, "channels": ch, "seconds": round(secs, 1), "verdict": verdict})
            out["preview-get-" + auth_label] = r
            verdicts.append(verdict)
            line("preview-get-" + auth_label, "ok" if r["status"] == 200 else "FAIL",
                 "status %d, type %s, content-length %s, accept-ranges %s, %d bytes, %ss, %d ADTS frames, %s Hz, %s ch, %.1fs -> %s" % (
                     r["status"], r["content_type"], r["content_length"], r["accept_ranges"], r["bytes"], r["elapsed_s"],
                     frames, rate, ch, secs, verdict))
        if "token" in qnames:
            if wait:
                time.sleep(65)
                r = stream_get(base, target)
                r.pop("data")
                out["preview-ttl"] = {"status": r["status"]}
                line("preview-ttl", "ok" if r["status"] == 404 else "info", "after 65 s: status %d" % r["status"])
            else:
                line("preview-ttl", "info", "skipped (--no-wait)")

    h = urllib.parse.urlsplit(base)
    try:
        conn = http.client.HTTPConnection(h.hostname, 8097, timeout=10)
        conn.request("GET", "/info", headers={"User-Agent": "Roadie-recorder"})
        r = conn.getresponse()
        body = r.read(100000)
        conn.close()
        try:
            keys = sorted(json.loads(body).keys())
        except Exception:
            keys = []
        out["stream-server"] = {"status": r.status, "keys": keys}
        line("stream-server", "info", "8097 /info status %d, keys: %s" % (r.status, ", ".join(keys) or "none"))
    except (OSError, http.client.HTTPException) as e:
        out["stream-server"] = {"error": type(e).__name__}
        line("stream-server", "info", "8097 unreachable: %s" % type(e).__name__)

    final = [v for k, v in out.items() if k.startswith("preview-get-")]
    summary = "full" if any(x.get("verdict") == "full" for x in final) else (
        "preview" if any(x.get("verdict") == "preview" for x in final) else "none")
    out["verdict"] = summary
    print("probe: verdict %s" % summary)
    if write:
        text = json.dumps(targets.scrub(out, fixture=False), indent=2, sort_keys=True) + "\n"
        path = os.path.join(ROOT, DOCS_REL, "track-audio-probe.json")
        with open(path, "w", encoding="utf-8") as f:
            f.write(text)
        problems = gate([path], targets, [])
        if problems:
            os.remove(path)
            die("probe file failed the secret gate (%s); removed" % ", ".join(r for _, r in problems))
        print("probe: wrote %s" % os.path.relpath(path, ROOT))


def main(argv):
    args = {"out": None, "events_seconds": 30, "check": False, "live": False, "probe": False, "write": False,
            "wait": True, "playlist_writes": False, "record_queue": False, "queue_id": None}
    i = 0

    def value(flag):
        # The argument after `flag`; a usage stop when it is missing (#0196).
        if i + 1 >= len(argv):
            die("%s needs a value\n%s" % (flag, __doc__))
        return argv[i + 1]

    while i < len(argv):
        a = argv[i]
        if a == "--check":
            args["check"] = True
        elif a == "--check-live":
            args["live"] = True
        elif a == "--probe-audio":
            args["probe"] = True
        elif a == "--write":
            args["write"] = True
        elif a == "--record-playlist-writes":
            args["playlist_writes"] = True
        elif a == "--record-queue":
            args["record_queue"] = True
        elif a == "--queue-id":
            args["queue_id"] = value(a)
            i += 1
        elif a in ("-h", "--help"):
            print(__doc__)
            return
        elif a == "--no-wait":
            args["wait"] = False
        elif a == "--out":
            args["out"] = value(a)
            i += 1
        elif a == "--events-seconds":
            args["events_seconds"] = int(value(a))
            i += 1
        else:
            die("unknown argument " + a)
        i += 1
    if args["playlist_writes"]:
        record_playlist_writes(args)
        return
    if args["record_queue"]:
        record_queue(args)
        return
    if args["probe"]:
        probe_audio(args["write"], args["wait"])
        return
    if args["live"]:
        rep = check_live()
        print("live: %d checks, %d failed" % (rep.total, rep.failed))
        sys.exit(2 if rep.failed else 0)
    if args["check"]:
        check()
    else:
        record(args)


def run(argv):
    """main() with network errors reduced to a class name: a TLS or DNS message can carry the host name."""
    try:
        main(argv)
    except ssl.SSLCertVerificationError:
        die("TLS certificate verification failed (the certificate or host name does not match; verification stays on)")
    except ssl.SSLError:
        die("TLS error")
    except (OSError, http.client.HTTPException, Closed) as e:
        die("network error: " + type(e).__name__)


if __name__ == "__main__":
    run(sys.argv[1:])

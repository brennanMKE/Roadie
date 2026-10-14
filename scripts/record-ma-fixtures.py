#!/usr/bin/python3 -I
"""Records Music Assistant protocol fixtures for SkinAmp (#0060). Host only, network only, read-only.

Run:   /usr/bin/python3 -I scripts/record-ma-fixtures.py [--out DIR] [--events-seconds N]
Check: /usr/bin/python3 -I scripts/record-ma-fixtures.py --check

Reads MUSIC_ASSISTANT_URL and MUSIC_ASSISTANT_TOKEN from .env itself. The token lives in one
variable, goes only into the `auth` frame and into Authorization headers of artwork probes, and is
never put in argv, the environment, a URL, a log line or a file. Sends only the commands in ALLOWED:
nothing that plays, pauses, seeks, changes volume, groups players, syncs or edits anything.
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
])
# Error-envelope probes. Harmless: an unknown command, never the real token on a failing path.
PROBES = frozenset(["skinamp/no_such_command"])

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
    return url, token


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
    cls = http.client.HTTPSConnection if scheme == "https" else http.client.HTTPConnection
    conn = cls(netloc, timeout=timeout)
    headers = {"Accept": "*/*", "User-Agent": "SkinAmp-recorder"}
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
    def __init__(self, base, transcript, token):
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
            sock = ssl.create_default_context().wrap_socket(sock, server_hostname=u.hostname)
        self.sock = sock
        key = base64.b64encode(os.urandom(16)).decode()
        req = ("GET /ws HTTP/1.1\r\nHost: %s\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
               "Sec-WebSocket-Key: %s\r\nSec-WebSocket-Version: 13\r\n\r\n" % (u.netloc, key))
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

    def __init__(self, base, transcript, token):
        self.ws = WS(base, transcript, token)
        self.next_id = 1
        self.events = []

    def first_frame(self, timeout=10):
        t = self.ws.recv(timeout)
        return json.loads(t) if t else None

    def call(self, command, args=None, timeout=10, probe=False, _auth_token=None):
        if command not in ALLOWED and not (probe and command in PROBES):
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
                        out[k] = "SkinAmp"
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
    for rel in (FIXTURE_REL, DOCS_REL):
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
    R("error-unknown-player", "players/get", {"player_id": "skinamp-no-such-player"})
    R("error-unknown-command", "skinamp/no_such_command", {}, probe=True)

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
    written = []
    shutil.rmtree(fix_dir, ignore_errors=True)
    os.makedirs(fix_dir, exist_ok=True)
    os.makedirs(docs_dir, exist_ok=True)
    for name, obj in fixtures.items():
        o = targets.scrub(obj, fixture=True)
        if name == "playlist-tracks":
            for fr in o.get("frames", []):
                if isinstance(fr.get("result"), list) and len(fr["result"]) > 5:
                    o.setdefault("original_item_counts", []).append(len(fr["result"]))
                    fr["result"] = fr["result"][:5]
                    o["truncated_to_5_items_per_frame"] = True
        p = os.path.join(fix_dir, name + ".json")
        data = json.dumps(o, indent=2, ensure_ascii=False) + "\n"
        with open(p, "w", encoding="utf-8") as f:
            f.write(data)
        written.append(p)
        n = len(o.get("frames", o.get("events", []))) if isinstance(o, dict) else 1
        summary.append((name + ".json", n, len(data)))
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


def check():
    base, token = read_env()
    st, _, body = http_get(base, "/info")
    if st != 200:
        die("GET /info returned %d" % st)
    targets = Targets(base, token, json.loads(body))
    files = owned_files(ROOT)
    if not files:
        die("nothing to check")
    problems = gate(files, targets, [os.path.join(ROOT, FIXTURE_REL)])
    if problems:
        print("SECRET GATE FAILED:")
        for path, rule in problems:
            print("  %s: %s" % (os.path.relpath(path, ROOT), rule))
        sys.exit(2)
    print("secret gate: passed (%d files)" % len(files))


def main(argv):
    args = {"out": None, "events_seconds": 30, "check": False}
    i = 0
    while i < len(argv):
        a = argv[i]
        if a == "--check":
            args["check"] = True
        elif a == "--out":
            i += 1
            args["out"] = argv[i]
        elif a == "--events-seconds":
            i += 1
            args["events_seconds"] = int(argv[i])
        else:
            die("unknown argument " + a)
        i += 1
    if args["check"]:
        check()
    else:
        record(args)


if __name__ == "__main__":
    main(sys.argv[1:])

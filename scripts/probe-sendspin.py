#!/usr/bin/python3 -I
"""Sendspin player smoke test for #0066. Host only, network only. Never plays, decodes or outputs audio.

Run:   /usr/bin/python3 -I scripts/probe-sendspin.py [--write]

Connects to the Music Assistant server in .env as a Sendspin player named "SkinAmp probe" through the
authenticated `/sendspin` proxy on the API port (first frame `{"type": "auth", "token", "client_id"}`), speaks
the legacy unencrypted wire that aiosendspin 9.1.1 (MA 2.10.6) and 10.x accept (`client/hello` with
`client_id` and `version`), syncs clocks with five `client/time` exchanges, reports `client/state`, checks
that `players/all` (read-only, over the normal API) lists the player, then sends `client/goodbye` and closes,
all within about 30 s. It sends no player, queue, volume or playback command. If the server starts a stream
anyway (someone pressed play on the probe in MA), it records only the frame type and size and leaves at once.

Prints only `probe:` lines with safe facts. With --write, saves the scrubbed frames to
docs/ma-protocol/sendspin-probe.json and runs the recorder's secret gate on it (deleted if the gate fails).
The token goes only into the two auth frames. Python 3.9 compatible (Apple's /usr/bin/python3).
"""
import importlib.util
import json
import os
import re
import socket
import sys
import time
import urllib.parse

HERE = os.path.dirname(os.path.abspath(__file__))
_spec = importlib.util.spec_from_file_location("record_ma_fixtures", os.path.join(HERE, "record-ma-fixtures.py"))
rmf = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(rmf)

CLIENT_ID = "skinamp-probe"
CLIENT_NAME = "SkinAmp probe"
OUT_REL = os.path.join(rmf.DOCS_REL, "sendspin-probe.json")
FAKE_SENDSPIN_ID = "A" * 43  # a Sendspin server_id is a 43-character base64url Curve25519 key
# Message types the probe may send on the Sendspin socket. None asks for playback.
SENDABLE = frozenset(["client/hello", "client/time", "client/state", "client/goodbye"])


class SendspinWS(rmf.WS):
    def recv_message(self, timeout):
        """("text", str) or ("binary", (type byte, length)) or None on timeout. Binary bodies are never kept."""
        deadline = time.time() + timeout
        while True:
            fr = self._try_parse()
            if fr is not None:
                fin, op, payload = fr
                if op == 9:
                    self._send_frame(10, payload)
                    continue
                if op == 10:
                    continue
                if op == 8:
                    raise rmf.Closed("server closed")
                self.frag += payload
                if not fin:
                    continue
                data, self.frag = self.frag, b""
                if op == 2 or (op == 0 and data[:1] not in (b"{", b"[")):
                    return "binary", (data[0] if data else None, len(data))
                return "text", data.decode("utf-8")
            remaining = deadline - time.time()
            if remaining <= 0:
                return None
            import select
            r, _, _ = select.select([self.sock], [], [], remaining)
            if not r:
                return None
            chunk = self.sock.recv(65536)
            if not chunk:
                raise rmf.Closed("connection closed")
            self.buf += chunk

    def send_msg(self, obj):
        if obj.get("type") not in SENDABLE:
            raise RuntimeError("message type not allowed: %r" % obj.get("type"))
        self._send_frame(1, json.dumps(obj).encode())


def now_us():
    return time.monotonic_ns() // 1000


def players_entry(session, client_id):
    rec = session.call("players/all")
    result = rmf.result_of(rec) or []
    for p in result:
        if not isinstance(p, dict):
            continue
        protocols = [o.get("output_protocol_id") for o in (p.get("output_protocols") or []) if isinstance(o, dict)]
        # A non-web Sendspin client is a PROTOCOL player: MA wraps it in a universal player about 15 s later,
        # listed under its own id with the client in output_protocols.
        if p.get("player_id") == client_id or client_id in protocols or p.get("name") == CLIENT_NAME:
            return p, len(result)
    return None, len(result)


def probe(write):
    base, token = rmf.read_env()
    out = {"client": {"client_id": CLIENT_ID, "name": CLIENT_NAME}}
    log = rmf.NullLog()

    api = rmf.Session(base, log, token)
    info = api.first_frame() or {}
    targets = rmf.Targets(base, token, info)
    out["info"] = {"server_version": info.get("server_version"), "schema_version": info.get("schema_version")}
    print("probe: info server %s schema %s" % (info.get("server_version"), info.get("schema_version")))
    auth = api.call("auth", {"token": token})
    if rmf.is_error(auth):
        rmf.die("API auth failed")
    me = (rmf.result_of(auth) or {}).get("user") or {}
    targets.username = me.get("username")
    before, count = players_entry(api, CLIENT_ID)
    print("probe: players-before %d players, probe listed %s" % (count, before is not None))
    out["players_before"] = {"count": count, "probe_listed": before is not None}

    # Is the direct Sendspin port reachable from here? TCP connect only, nothing sent.
    host = urllib.parse.urlsplit(base).hostname
    try:
        socket.create_connection((host, 8927), timeout=3).close()
        direct = True
    except OSError:
        direct = False
    out["direct_8927_tcp"] = direct
    print("probe: direct-8927 tcp reachable %s" % direct)

    ws = SendspinWS(base, log, token, path="/sendspin")
    frames = []
    t0 = time.time()

    def note(direction, obj):
        frames.append({"t": round(time.time() - t0, 3), "dir": direction, "frame": obj})

    def recv_json(timeout):
        m = ws.recv_message(timeout)
        if m is None:
            return None
        kind, val = m
        if kind == "binary":
            note("in", {"binary_type": val[0], "bytes": val[1]})
            return {"_binary": val}
        obj = json.loads(val)
        note("in", obj)
        return obj

    # 1. Proxy auth (the MA token; the proxy registers client_id for this user's sessions).
    ws._send_frame(1, json.dumps({"type": "auth", "token": token, "client_id": CLIENT_ID}).encode())
    note("out", {"type": "auth", "token": "<redacted>", "client_id": CLIENT_ID})
    ack = recv_json(10)
    ok = isinstance(ack, dict) and ack.get("type") == "auth_ok"
    print("probe: proxy-auth %s" % ("ok" if ok else "FAIL (%s)" % (sorted(ack) if isinstance(ack, dict) else ack)))
    out["proxy_auth_ok"] = ok
    if not ok:
        ws.close()
        return finish(out, frames, targets, write, api)

    # 2. Legacy hello: client_id and version in the hello, player@v1 support with commands (aiosendspin 9.1.1 shape).
    hello = {"type": "client/hello", "payload": {
        "client_id": CLIENT_ID, "name": CLIENT_NAME, "version": 1,
        "supported_roles": ["player@v1"],
        "device_info": {"product_name": "SkinAmp", "manufacturer": "SkinAmp", "software_version": "probe"},
        "player@v1_support": {
            "supported_formats": [{"codec": "pcm", "channels": 2, "sample_rate": 48000, "bit_depth": 16}],
            "buffer_capacity": 1048576,
            "supported_commands": ["volume", "mute"],
        },
    }}
    ws.send_msg(hello)
    note("out", hello)
    server_hello = None
    deadline = time.time() + 10
    while time.time() < deadline and server_hello is None:
        m = recv_json(deadline - time.time())
        if isinstance(m, dict) and m.get("type") == "server/hello":
            server_hello = m
    if server_hello is None:
        print("probe: server-hello FAIL (none within 10 s)")
        ws.close()
        return finish(out, frames, targets, write, api)
    sp = server_hello.get("payload") or {}
    print("probe: server-hello ok keys %s, version %s, active_roles %s, connection_reason %s"
          % (sorted(sp), sp.get("version"), sp.get("active_roles"), sp.get("connection_reason")))

    # 3. Clock: five sequential exchanges (the initial client/state is due within 5 s of the hello).
    samples = []
    for _ in range(5):
        t1 = now_us()
        ws.send_msg({"type": "client/time", "payload": {"client_transmitted": t1}})
        note("out", {"type": "client/time", "payload": {"client_transmitted": t1}})
        deadline = time.time() + 3
        while time.time() < deadline:
            m = recv_json(deadline - time.time())
            if isinstance(m, dict) and m.get("type") == "server/time":
                t4 = now_us()
                p = m.get("payload") or {}
                if p.get("client_transmitted") == t1:
                    t2, t3 = p.get("server_received"), p.get("server_transmitted")
                    samples.append({"rtt_us": (t4 - t1) - (t3 - t2), "offset_us": ((t2 - t1) + (t3 - t4)) // 2,
                                    "max_error_us": ((t4 - t1) - (t3 - t2)) // 2})
                break
            if isinstance(m, dict) and "_binary" in m:
                break
    if samples:
        rtts = sorted(s["rtt_us"] for s in samples)
        offs = [s["offset_us"] for s in samples]
        print("probe: clock ok %d/5 samples, rtt min %d us max %d us, offset spread %d us"
              % (len(samples), rtts[0], rtts[-1], max(offs) - min(offs)))
    else:
        print("probe: clock FAIL (no server/time)")
    out["clock"] = {"samples": len(samples),
                    "rtt_us": sorted(s["rtt_us"] for s in samples),
                    "offset_spread_us": (max(s["offset_us"] for s in samples) - min(s["offset_us"] for s in samples)) if samples else None}

    # 4. Initial client/state (aiosendspin 9.1.1 keys: static_delay_ms, not output_delay_ms).
    state = {"type": "client/state", "payload": {"available": True, "player": {
        "volume": 50, "muted": False, "static_delay_ms": 0,
        "required_lead_time_ms": 500, "min_buffer_ms": 200, "supported_commands": []}}}
    ws.send_msg(state)
    note("out", state)

    # 5. Listen briefly. Leave at once if a stream starts or audio arrives.
    streamed = False
    deadline = time.time() + 6
    while time.time() < deadline:
        m = recv_json(deadline - time.time())
        if m is None:
            break
        if isinstance(m, dict) and ("_binary" in m or m.get("type") == "stream/start"):
            streamed = True
            break
    types = [f["frame"].get("type", "binary") for f in frames if f["dir"] == "in" and isinstance(f["frame"], dict)]
    print("probe: received %s" % ", ".join(types))
    if streamed:
        print("probe: stream started by the server; leaving without reading audio")
    out["stream_started"] = streamed

    # 6. Is it a Music Assistant player now? Poll players/all for up to 35 s (MA's protocol-linking delay is 15 s),
    # servicing the socket in between; leave at once if a stream starts.
    entry, count = None, 0
    poll_end = time.time() + 35
    while not streamed and time.time() < poll_end:
        entry, count = players_entry(api, CLIENT_ID)
        if entry:
            break
        listen_end = time.time() + 3
        while time.time() < listen_end:
            m = recv_json(max(0.05, listen_end - time.time()))
            if isinstance(m, dict) and ("_binary" in m or m.get("type") == "stream/start"):
                streamed = True
                break
    out["stream_started"] = streamed
    if entry:
        protocols = [o for o in (entry.get("output_protocols") or []) if isinstance(o, dict)]
        mine = [o for o in protocols if o.get("output_protocol_id") == CLIENT_ID]
        print("probe: players-during listed after %.0f s, player_id is client_id %s, provider %s, type %s, "
              "available %s, name matches %s, hide_in_ui %s, features %s, client as output protocol %s"
              % (time.time() - t0, entry.get("player_id") == CLIENT_ID, entry.get("provider"), entry.get("type"),
                 entry.get("available"), entry.get("name") == CLIENT_NAME, entry.get("hide_in_ui"),
                 entry.get("supported_features"),
                 [(o.get("protocol_domain"), o.get("available"), o.get("is_native")) for o in mine]))
    else:
        print("probe: players-during FAIL (probe not in players/all, %d players)" % count)
    out["player_during"] = entry

    # 7. Goodbye, close, and look again.
    bye = {"type": "client/goodbye", "payload": {"reason": "user_request"}}
    try:
        ws.send_msg(bye)
        note("out", bye)
    except OSError:
        pass
    ws.close()
    time.sleep(3)
    after, count = players_entry(api, CLIENT_ID)
    print("probe: players-after listed %s, available %s" % (after is not None, after and after.get("available")))
    out["player_after"] = {"listed": after is not None, "available": after.get("available") if after else None}
    print("probe: elapsed %.1f s" % (time.time() - t0))
    return finish(out, frames, targets, write, api)


SENDSPIN_KEY = re.compile(r"[A-Za-z0-9_-]{43}")
ADDRESS_KEYS = {"ip_address", "mac_address", "address", "addresses", "identifiers", "ip", "host"}


def drop_addresses(o):
    """A player entry can carry this Mac's addresses (IPv6, MAC) that the IPv4 scrubber misses."""
    if isinstance(o, dict):
        return {k: ("<scrubbed>" if k in ADDRESS_KEYS and v else drop_addresses(v)) for k, v in o.items()}
    if isinstance(o, list):
        return [drop_addresses(v) for v in o]
    if isinstance(o, str) and SENDSPIN_KEY.fullmatch(o) and o != FAKE_SENDSPIN_ID:
        return "B" * 43  # another Sendspin client's id (its public key), e.g. a browser in can_group_with
    return o


def finish(out, frames, targets, write, api):
    try:
        api.ws.close()
    except Exception:
        pass
    out["frames"] = frames
    scrubbed = drop_addresses(targets.scrub(out))
    # The legacy server/hello carries the Sendspin server's own id (its public key); replace it.
    for f in scrubbed["frames"]:
        fr = f.get("frame")
        if isinstance(fr, dict) and fr.get("type") == "server/hello":
            p = fr.get("payload") or {}
            if "server_id" in p:
                p["server_id"] = FAKE_SENDSPIN_ID
    if not write:
        return
    path = os.path.join(rmf.ROOT, OUT_REL)
    with open(path, "w", encoding="utf-8") as f:
        json.dump(scrubbed, f, indent=2, sort_keys=True)
        f.write("\n")
    problems = rmf.gate([path], targets, [])
    if problems:
        os.remove(path)
        print("probe: SECRET GATE FAILED (%s); file removed" % ", ".join(sorted(set(r for _, r in problems))))
        sys.exit(2)
    print("probe: wrote %s (secret gate passed)" % OUT_REL)


def main(argv):
    write = False
    for a in argv:
        if a == "--write":
            write = True
        else:
            rmf.die("unknown argument " + a)
    probe(write)


if __name__ == "__main__":
    try:
        main(sys.argv[1:])
    except (OSError, rmf.Closed) as e:
        rmf.die("network error: " + type(e).__name__)

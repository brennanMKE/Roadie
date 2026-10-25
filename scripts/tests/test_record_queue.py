"""The --record-queue run (#0196), driven by a fake Session; no server, no .env.

Run: /usr/bin/python3 -I -B scripts/tests/test_record_queue.py
"""
import importlib.util
import os
import sys
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
sys.dont_write_bytecode = True
_spec = importlib.util.spec_from_file_location(
    "record_ma_fixtures", os.path.join(HERE, "..", "record-ma-fixtures.py"))
rmf = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(rmf)


def ok(result=None):
    return {"command": "", "args": {}, "frames": [{"message_id": "x", "result": result, "partial": False}]}


class FakeSession:
    """Answers `player_queues/all` with `queues`; refuses commands off the read-only allowlist, as Session does."""

    def __init__(self, queues):
        self.queues = queues
        self.sent = []

    def call(self, command, args=None, timeout=10):
        if command not in rmf.ALLOWED:
            raise RuntimeError("not allowed: " + command)
        self.sent.append((command, args or {}))
        if command == "player_queues/all":
            return ok(self.queues)
        if command == "player_queues/items":
            return ok([{"index": 0, "queue_item_id": "q%d" % i} for i in range(3)])
        return ok({})


QUEUES = [
    {"queue_id": "empty", "items": 0, "state": "idle"},
    {"queue_id": "paused", "items": 4, "state": "paused"},
    {"queue_id": "playing", "items": 60, "state": "playing"},
]


class RecordQueueTests(unittest.TestCase):
    def test_records_the_playing_queue(self):
        s = FakeSession(QUEUES)
        fixtures = rmf.record_queue_calls(s)
        self.assertEqual(set(fixtures), rmf.QUEUE_FIXTURES - {"events-queue"})
        for _command, args in s.sent:
            if "queue_id" in args or "player_id" in args:
                self.assertEqual(args.get("queue_id", args.get("player_id")), "playing")
        offsets = [a["offset"] for c, a in s.sent if c == "player_queues/items"]
        self.assertEqual(offsets, [0, rmf.QUEUE_PAGE])
        self.assertEqual(rmf.TRUNCATE["player-queue-items-loaded"], 50)

    def test_queue_id_names_the_queue(self):
        s = FakeSession(QUEUES)
        rmf.record_queue_calls(s, "paused")
        self.assertIn(("player_queues/get", {"queue_id": "paused"}), s.sent)

    def test_sends_only_reads(self):
        s = FakeSession(QUEUES)
        rmf.record_queue_calls(s)
        for command, _args in s.sent:
            self.assertIn(command, rmf.ALLOWED)
            self.assertNotIn(command, rmf.ALLOWED_WRITES)

    def test_dies_when_no_queue_has_items(self):
        s = FakeSession([{"queue_id": "empty", "items": 0, "state": "playing"}])
        with self.assertRaises(SystemExit):
            rmf.record_queue_calls(s)
        self.assertNotIn("player_queues/items", [c for c, _ in s.sent])


if __name__ == "__main__":
    unittest.main()

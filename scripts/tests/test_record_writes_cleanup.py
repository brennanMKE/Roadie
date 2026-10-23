"""Cleanup of the --record-playlist-writes run (#0133), driven by a fake Session; no server, no .env.

Run: /usr/bin/python3 -I -B scripts/tests/test_record_writes_cleanup.py
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

NAME = "Roadie fixture test"
TRACKS = [
    {"item_id": "1", "uri": "library://track/1", "name": "First Song", "favorite": False},
    {"item_id": "2", "uri": "library://track/2", "name": "Second Song", "favorite": False},
]


def ok(result=None):
    return {"frames": [{"message_id": "x", "result": result}]}


ERROR = {"frames": [{"message_id": "x", "error_code": 999, "details": "boom"}]}
TIMEOUT = {"frames": []}


class FakeSession:
    """Answers every command with a success unless `script` maps the command to a list of
    responses (a dict to return, or an exception instance/class to raise), consumed in order."""

    def __init__(self, script=None):
        self.script = {k: list(v) for k, v in (script or {}).items()}
        self.sent = []

    def call(self, command, args=None, timeout=10):
        self.sent.append(command)
        queue = self.script.get(command)
        if queue:
            r = queue.pop(0)
            if isinstance(r, BaseException) or (isinstance(r, type) and issubclass(r, BaseException)):
                raise r
            return r
        if command == "music/playlists/create_playlist":
            return ok({"item_id": "77", "name": args["name"]})
        if command == "music/playlists/get":
            return ok({"item_id": "77", "name": NAME})
        return ok(None)


def run(script=None):
    s = FakeSession(script)
    lines = []
    raised = None
    failed = None
    try:
        failed = rmf.run_playlist_writes(s, [dict(t) for t in TRACKS], NAME, {},
                                         report=lines.append, sleep=lambda _s: None)
    except BaseException as e:  # the test inspects interrupts
        raised = e
    return s, lines, failed, raised


def cleanup_lines(lines):
    return [line for line in lines if line.startswith("CLEANUP FAILED")]


class CleanupTests(unittest.TestCase):
    def test_happy_path_has_no_warning(self):
        s, lines, failed, raised = run()
        self.assertIsNone(failed)
        self.assertIsNone(raised)
        self.assertEqual(cleanup_lines(lines), [])
        self.assertEqual(s.sent[-1], "music/library/remove_item")
        self.assertEqual(s.sent.count("music/favorites/remove_item"), 1)

    def test_delete_error_frame_is_cleanup_failed(self):
        _, lines, _, raised = run({"music/library/remove_item": [ERROR]})
        self.assertIsNone(raised)
        msgs = cleanup_lines(lines)
        self.assertEqual(len(msgs), 1)
        self.assertIn("error frame", msgs[0])
        self.assertIn(repr(NAME), msgs[0])

    def test_delete_timeout_is_cleanup_failed(self):
        _, lines, _, _ = run({"music/library/remove_item": [TIMEOUT]})
        msgs = cleanup_lines(lines)
        self.assertEqual(len(msgs), 1)
        self.assertIn("no reply", msgs[0])
        self.assertIn(repr(NAME), msgs[0])

    def test_interrupt_during_delete_reports_then_reraises(self):
        _, lines, _, raised = run({"music/library/remove_item": [KeyboardInterrupt]})
        self.assertIsInstance(raised, KeyboardInterrupt)
        msgs = cleanup_lines(lines)
        self.assertEqual(len(msgs), 1)
        self.assertIn("KeyboardInterrupt", msgs[0])
        self.assertIn(repr(NAME), msgs[0])

    def test_favorite_restore_failure_names_the_track(self):
        # The in-run remove gets an error frame; the cleanup retry times out.
        s, lines, _, _ = run({"music/favorites/remove_item": [ERROR, TIMEOUT]})
        msgs = cleanup_lines(lines)
        self.assertEqual(len(msgs), 1)
        self.assertIn("un-favorite the track 'First Song'", msgs[0])
        self.assertEqual(s.sent.count("music/favorites/remove_item"), 2)
        self.assertEqual(s.sent[-1], "music/library/remove_item")  # the playlist is still deleted

    def test_favorite_restored_in_cleanup_after_a_step_fails(self):
        s, lines, failed, _ = run({"music/favorites/remove_item": [RuntimeError("lost"), ok()]})
        self.assertIn("RuntimeError", failed)
        self.assertEqual(cleanup_lines(lines), [])
        self.assertEqual(s.sent.count("music/favorites/remove_item"), 2)

    def test_interrupt_during_favorite_restore_still_deletes_then_reraises(self):
        s, lines, _, raised = run({"music/favorites/remove_item": [ERROR, KeyboardInterrupt]})
        self.assertIsInstance(raised, KeyboardInterrupt)
        msgs = cleanup_lines(lines)
        self.assertEqual(len(msgs), 1)
        self.assertIn("'First Song'", msgs[0])
        self.assertEqual(s.sent[-1], "music/library/remove_item")

    def test_create_timeout_reports_the_name(self):
        s, lines, failed, _ = run({"music/playlists/create_playlist": [TIMEOUT]})
        self.assertIn("create_playlist", failed)
        msgs = cleanup_lines(lines)
        self.assertEqual(len(msgs), 1)
        self.assertIn("may exist", msgs[0])
        self.assertIn(repr(NAME), msgs[0])
        self.assertNotIn("music/library/remove_item", s.sent)

    def test_create_interrupted_reports_the_name_and_reraises(self):
        _, lines, _, raised = run({"music/playlists/create_playlist": [KeyboardInterrupt]})
        self.assertIsInstance(raised, KeyboardInterrupt)
        msgs = cleanup_lines(lines)
        self.assertEqual(len(msgs), 1)
        self.assertIn(repr(NAME), msgs[0])


if __name__ == "__main__":
    unittest.main(verbosity=2)

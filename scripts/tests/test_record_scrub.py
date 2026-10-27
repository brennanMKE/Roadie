"""Targets.scrub keeps the server's own playlist owner (#0221); no server, no .env.

Run: /usr/bin/python3 -I -B scripts/tests/test_record_scrub.py
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


def targets():
    return rmf.Targets("http://ma.example.test:8095", "fake-token", {"server_id": "fake-id", "name": "Home"})


class ScrubOwnerTests(unittest.TestCase):
    def test_owner_music_assistant_is_kept(self):
        self.assertEqual(targets().scrub({"owner": "Music Assistant"}), {"owner": "Music Assistant"})

    def test_other_owners_become_user(self):
        self.assertEqual(targets().scrub({"owner": "Brennan"}), {"owner": "user"})


if __name__ == "__main__":
    unittest.main()

#!/usr/bin/env python3
"""Guard against repeated Mac builds and incomplete GitHub API responses."""

from pathlib import Path
import tempfile
import unittest

from select_cef_candidate import current_version, read_json, select


class CandidateSelectionTests(unittest.TestCase):
    def setUp(self):
        self.upstream = {"tag_name": "v0.44.0"}
        self.release = {"tag_name": "1.0", "assets": [
            {"name": "KCDMP-Mac-v0.44.0.zip", "state": "uploaded", "size": 4689194}]}

    def test_renamed_published_release_prevents_rebuild(self):
        self.assertEqual(select(self.upstream, [[self.release]], "0.44.0"),
                         ("v0.44.0", "0.44.0", "false"))

    def test_draft_asset_prevents_rebuild(self):
        self.release["draft"] = True
        self.assertEqual(select(self.upstream, [[], [self.release]], "0.44.0")[2], "false")

    def test_no_existing_asset_selects_current_or_candidate(self):
        self.assertEqual(select(self.upstream, [[]], "0.44.0")[2], "current")
        self.assertEqual(select(self.upstream, [[]], "0.43.0")[2], "candidate")
        self.release["assets"][0]["size"] = 0
        self.assertEqual(select(self.upstream, [[self.release]], "0.44.0")[2], "current")

    def test_incomplete_api_data_fails_instead_of_building(self):
        for upstream, releases in [
            ({}, [[]]), ({"tag_name": None}, [[]]),
            (self.upstream, None), (self.upstream, [[{"assets": None}]]),
            (self.upstream, [[self.release], None]),
            (self.upstream, [[{"assets": [{"name": None, "state": "uploaded", "size": 1}]}]]),
            (self.upstream, [[{"assets": [{"name": "other.zip", "state": "uploaded", "size": None}]}]]),
        ]:
            with self.subTest(upstream=upstream, releases=releases):
                with self.assertRaises(ValueError):
                    select(upstream, releases, "0.44.0")

    def test_missing_and_unreadable_inputs_fail(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            with self.assertRaises(ValueError):
                read_json(root / "missing.json")
            invalid = root / "invalid.json"
            invalid.write_text("not JSON")
            with self.assertRaises(ValueError):
                read_json(invalid)
            with self.assertRaises(ValueError):
                current_version(root / "missing.h")
            header = root / "patch_guard.h"
            header.write_text('#include "target-0.44.0.h"\n')
            self.assertEqual(current_version(header), "0.44.0")
            header.write_text("no target")
            with self.assertRaises(ValueError):
                current_version(header)


if __name__ == "__main__":
    unittest.main()

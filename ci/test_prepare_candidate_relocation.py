import sys
from pathlib import Path
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "cef-source/client_compat/bridge"))
import prepare_candidate as candidate


class Image:
    def __init__(self, functions): self.functions = functions
    def bytes_at(self, start, length): return b"\x55" * length
    def section_at(self, start): return ".text"


class RelocationTests(unittest.TestCase):
    def setUp(self):
        self.old = Image({100: 120})
        self.branches = {1: 2}
        self.data = {3: 4}
        self.totals = {"functions": 0}

    def locate(self, functions, compare):
        with patch.object(candidate, "compare_function", side_effect=compare):
            return candidate.reviewed_location("fixture", self.old, Image(functions), 100, 120,
                                               1000, Path("objdump"), self.branches, self.data, self.totals)

    @staticmethod
    def matching(*args):
        start, branches, data, totals = args[5], args[8], args[9], args[10]
        branches[100] = start
        data[200] = start + 4
        totals["functions"] += 1

    def test_unique_relocation_and_failed_candidate_are_transactional(self):
        def compare(*args):
            self.matching(*args)
            if args[5] == 1010: raise ValueError("different instruction")
        self.assertEqual(self.locate({1010: 1030, 1040: 1060}, compare), 1040)
        self.assertEqual(self.branches, {1: 2, 100: 1040})
        self.assertEqual(self.data, {3: 4, 200: 1044})
        self.assertEqual(self.totals["functions"], 1)

    def test_ambiguous_or_missing_match_refuses_without_state_change(self):
        for functions in [{1010: 1030, 1040: 1060}, {}]:
            with self.subTest(functions=functions), self.assertRaises(ValueError):
                self.locate(functions, self.matching)
            self.assertEqual(self.branches, {1: 2})
            self.assertEqual(self.data, {3: 4})
            self.assertEqual(self.totals, {"functions": 0})

    def test_changed_existing_entry_does_not_search_for_another_function(self):
        def mismatch(*args): raise ValueError("different instruction")
        with self.assertRaisesRegex(ValueError, "different instruction"):
            self.locate({1000: 1020, 1040: 1060}, mismatch)
        with self.assertRaisesRegex(ValueError, "unwind function size"):
            self.locate({1000: 1021, 1040: 1060}, self.matching)

    def test_disassembler_read_failure_is_not_treated_as_no_match(self):
        def failure(*args): raise OSError("could not read image")
        with self.assertRaises(OSError):
            self.locate({1040: 1060}, failure)


if __name__ == "__main__": unittest.main()

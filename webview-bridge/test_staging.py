import hashlib
from pathlib import Path
import tempfile
import unittest
from run_original_probe import ORIGINALS, staged_loader


class StagingTests(unittest.TestCase):
    def setUp(self):
        self.scratch = tempfile.TemporaryDirectory()
        self.addCleanup(self.scratch.cleanup)
        self.game = Path(self.scratch.name) / "game"
        self.game.mkdir()
        for name in ORIGINALS:
            path = self.game / name
            path.parent.mkdir(exist_ok=True)
            path.write_bytes(name.encode())
        self.expected = hashlib.sha256((self.game / ORIGINALS[0]).read_bytes()).hexdigest()
        self.loader = Path(self.scratch.name) / "loader.dll"
        self.loader.write_bytes(b"MZ fixture loader")

    def test_failure_inside_test_restores_only_own_loader(self):
        with self.assertRaisesRegex(RuntimeError, "probe failed"):
            with staged_loader(self.game, self.loader, self.expected) as record:
                self.assertTrue((self.game / "WebView2Loader.dll").exists())
                raise RuntimeError("probe failed")
        self.assertTrue(record["loader_removed"])
        self.assertTrue(all(record["unchanged_originals"].values()))

    def test_existing_loader_is_preserved(self):
        target = self.game / "WebView2Loader.dll"
        target.write_bytes(b"existing file")
        with self.assertRaises(FileExistsError):
            with staged_loader(self.game, self.loader, self.expected):
                self.fail("Existing loader accepted")
        self.assertEqual(target.read_bytes(), b"existing file")

    def test_wrong_target_and_missing_data_fail_before_install(self):
        with self.assertRaisesRegex(ValueError, "hash changed"):
            with staged_loader(self.game, self.loader, "0" * 64):
                self.fail("Changed target accepted")
        (self.game / ORIGINALS[1]).unlink()
        with self.assertRaises(FileNotFoundError):
            with staged_loader(self.game, self.loader, self.expected):
                self.fail("Missing client accepted")
        self.assertFalse((self.game / "WebView2Loader.dll").exists())

    def test_replaced_loader_is_never_deleted(self):
        target = self.game / "WebView2Loader.dll"
        with self.assertRaisesRegex(ValueError, "replaced"):
            with staged_loader(self.game, self.loader, self.expected):
                target.write_bytes(b"replacement")
        self.assertEqual(target.read_bytes(), b"replacement")


if __name__ == "__main__":
    unittest.main()

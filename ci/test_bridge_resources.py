import hashlib
import io
from pathlib import Path
import struct
import tempfile
import unittest
from unittest.mock import patch
import warnings
import zipfile

from prepare_bridge_resources import download, prepare


def image(machine=0x8664):
    data = bytearray(256)
    data[:2] = b'MZ'
    struct.pack_into('<I', data, 0x3c, 64)
    data[64:68] = b'PE\0\0'
    struct.pack_into('<H', data, 68, machine)
    struct.pack_into('<H', data, 88, 0x20b)
    return bytes(data)


class ResourcesTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.archive = self.root / 'official.zip'
        self.checksum = self.root / 'official.zip.sha256'
        self.bridge = self.root / 'bridge.dll'
        self.helper = self.root / 'helper.dll'
        self.dock = self.root / 'dock.dylib'
        self.bridge.write_bytes(image())
        self.helper.write_bytes(image())
        self.dock.write_bytes(b'\xca\xfe\xba\xbe' + bytes(28) + b'KCDMP_DOCK_POLICY_ABI_1')
        self.client = image() + b'client'
        self.client_sha = hashlib.sha256(self.client).hexdigest()
        self.write_archive()

    def write_archive(self, launcher=None, ui=True, duplicate=False):
        with zipfile.ZipFile(self.archive, 'w') as package:
            package.writestr('KcdMp_launcher.exe', image() if launcher is None else launcher)
            package.writestr('KcdMp_client.dll', self.client)
            if ui:
                package.writestr('ui/launcher.html', '<html>fixture</html>')
            if duplicate:
                with warnings.catch_warnings():
                    warnings.simplefilter('ignore', UserWarning)
                    package.writestr('KcdMp_launcher.exe', image())
        self.checksum.write_text(hashlib.sha256(self.archive.read_bytes()).hexdigest() + '\n')

    def prepare(self, digest=None):
        return prepare(self.archive, self.checksum, '0.50.0', self.client_sha if digest is None else digest,
                       self.bridge, self.helper, self.dock)

    def test_valid_package_binds_launcher_client_bridge_and_helper(self):
        manifest = self.prepare()
        self.assertEqual(manifest['client_version'], '0.50.0')
        self.assertEqual(manifest['client_sha256'], self.client_sha)
        self.assertEqual(manifest['launcher_sha256'], hashlib.sha256(image()).hexdigest())
        self.assertEqual(manifest['cef_helper_sha256'], hashlib.sha256(self.helper.read_bytes()).hexdigest())
        self.assertEqual(manifest['dock_helper_abi'], 1)

    def test_invalid_missing_and_zero_checksum_fail(self):
        for value in ('', 'null', '0', '0'*64):
            self.checksum.write_text(value)
            with self.assertRaises(ValueError):
                self.prepare()
        self.checksum.unlink()
        with self.assertRaises(FileNotFoundError):
            self.prepare()

    def test_changed_client_and_missing_ui_fail(self):
        with self.assertRaisesRegex(ValueError, 'selected CEF target'):
            self.prepare('0'*64)
        self.write_archive(ui=False)
        with self.assertRaises(KeyError):
            self.prepare()

    def test_wrong_architecture_and_duplicate_paths_fail(self):
        self.write_archive(launcher=image(0x14c))
        with self.assertRaisesRegex(ValueError, 'AMD64'):
            self.prepare()
        self.write_archive(duplicate=True)
        with self.assertRaisesRegex(ValueError, 'Duplicate'):
            self.prepare()

    def test_read_errors_and_damaged_bundled_files_are_not_absence(self):
        self.helper.unlink()
        with self.assertRaises(FileNotFoundError):
            self.prepare()
        self.helper.write_bytes(b'MZ truncated')
        with self.assertRaisesRegex(ValueError, 'AMD64'):
            self.prepare()

    def test_download_cleanup_preserves_existing_destination_and_other_partial_files(self):
        destination = self.root / 'download.zip'
        destination.write_bytes(b'existing archive')
        other = self.root / 'download.zip.part'
        other.write_bytes(b'another download')
        class Reply(io.BytesIO):
            url = 'https://publisher.example/archive.zip'
        with patch('prepare_bridge_resources.urllib.request.urlopen', return_value=Reply(b'too large')):
            with self.assertRaisesRegex(ValueError, 'size limit'):
                download(Reply.url, destination, 2)
        self.assertEqual(destination.read_bytes(), b'existing archive')
        self.assertEqual(other.read_bytes(), b'another download')
        self.assertEqual(list(self.root.glob('download.zip.*.part')), [])
        with patch('prepare_bridge_resources.urllib.request.urlopen', side_effect=OSError('read failed')):
            with self.assertRaises(OSError):
                download(Reply.url, destination, 128)
        self.assertEqual(destination.read_bytes(), b'existing archive')
        with patch('prepare_bridge_resources.urllib.request.urlopen', return_value=Reply(b'complete')):
            download(Reply.url, destination, 128)
        self.assertEqual(destination.read_bytes(), b'complete')

    def test_native_dock_helper_missing_or_wrong_format_fails(self):
        self.dock.unlink()
        with self.assertRaises(FileNotFoundError):
            self.prepare()
        for value in (b'', b'null', image(), b'\xca\xfe\xba\xbe' + bytes(60)):
            self.dock.write_bytes(value)
            with self.assertRaisesRegex(ValueError, 'native Dock helper'):
                self.prepare()


if __name__ == '__main__':
    unittest.main()

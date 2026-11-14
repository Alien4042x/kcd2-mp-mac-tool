#!/usr/bin/env python3
"""Check the complete distributable without launching Steam or the game."""
import argparse
import hashlib
import json
from pathlib import Path
import plistlib
import subprocess

from prepare_bridge_resources import amd64


def check(app):
    resources = app / 'Contents/Resources'
    info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
    if info.get('CFBundleDisplayName') != 'KCD2MP Mac' or not info.get('NSMicrophoneUsageDescription'):
        raise ValueError('App name or microphone usage description is missing')
    target = json.loads((resources / 'launcher-target.json').read_text())
    for field in ('client_sha256', 'launcher_sha256', 'bridge_sha256', 'cef_helper_sha256'):
        value = target.get(field)
        if not isinstance(value, str) or len(value) != 64 or any(c not in '0123456789abcdef' for c in value):
            raise ValueError('Invalid packaged target hash')
    files = {
        'WebView2Loader.dll': 'bridge_sha256',
        'cef-compat/client_compat/bin/KcdMpCefCompat.dll': 'cef_helper_sha256',
        'cef-compat/client_compat/loader/bin/kcdmp_compat_loader.exe': None,
        'cef-compat/client_compat/loader/bin/kcdmp_compat_watcher.exe': None,
    }
    for name, digest in files.items():
        data = (resources / name).read_bytes()
        amd64(data)
        if digest and hashlib.sha256(data).hexdigest() != target[digest]:
            raise ValueError('Packaged helper hash mismatch: ' + name)
    dock = resources / 'libKcdMpDockPolicy.dylib'
    if target.get('dock_helper_abi') != 1 or b'KCDMP_DOCK_POLICY_ABI_1' not in dock.read_bytes():
        raise ValueError('Packaged native Dock helper ABI mismatch')
    architectures = subprocess.check_output(['lipo', '-archs', str(dock)], text=True).split()
    if set(architectures) != {'arm64', 'x86_64'}:
        raise ValueError('Dock helper must support both Wine host architectures')
    binary = app / 'Contents/MacOS' / info['CFBundleExecutable']
    subprocess.run([str(binary.resolve()), '--self-test'], check=True, timeout=20)
    print(f'Complete KCD2MP Mac bundle verified for client {target["client_version"]}')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('app', type=Path)
    check(parser.parse_args().app)

#!/usr/bin/env python3
"""Bind packaged bridge resources to a publisher-verified launcher and client."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import struct
import sys
import tempfile
import urllib.request
import zipfile


def sha(data):
    return hashlib.sha256(data).hexdigest()


def amd64(data):
    if len(data) < 64 or data[:2] != b'MZ':
        raise ValueError('Expected an AMD64 PE image')
    offset = struct.unpack_from('<I', data, 0x3c)[0]
    if offset + 26 > len(data) or data[offset:offset+4] != b'PE\0\0' or struct.unpack_from('<H', data, offset+4)[0] != 0x8664:
        raise ValueError('Expected an AMD64 PE image')
    if struct.unpack_from('<H', data, offset+24)[0] != 0x20b:
        raise ValueError('Expected a PE32+ image')


def prepare(archive, checksum, version, client_sha, bridge, helper, dock_helper):
    words = checksum.read_text().split()
    if not words or not re.fullmatch(r'[0-9a-f]{64}', words[0]):
        raise ValueError('Invalid publisher archive checksum')
    if sha(archive.read_bytes()) != words[0]:
        raise ValueError('Publisher archive checksum mismatch')
    with zipfile.ZipFile(archive) as package:
        if len(package.namelist()) != len(set(package.namelist())):
            raise ValueError('Duplicate archive paths')
        for name in ('KcdMp_launcher.exe', 'KcdMp_client.dll', 'ui/launcher.html'):
            if package.getinfo(name).file_size <= 0 or package.getinfo(name).file_size > 128*1024*1024:
                raise ValueError('Missing or oversized launcher input')
        launcher = package.read('KcdMp_launcher.exe')
        client = package.read('KcdMp_client.dll')
        amd64(launcher)
        amd64(client)
        if sha(client) != client_sha:
            raise ValueError('Official archive differs from selected CEF target')
    bridge_data, helper_data = bridge.read_bytes(), helper.read_bytes()
    amd64(bridge_data)
    amd64(helper_data)
    dock_data = dock_helper.read_bytes()
    if len(dock_data) < 32 or dock_data[:4] not in (b'\xca\xfe\xba\xbe', b'\xca\xfe\xba\xbf') or b'KCDMP_DOCK_POLICY_ABI_1' not in dock_data:
        raise ValueError('Expected a universal native Dock helper')
    # Xcode stripping and local signing can change Mach-O bytes. Its ABI is
    # stable across those operations and bundle signing seals the resource.
    return dict(client_version=version, client_sha256=client_sha, launcher_sha256=sha(launcher),
                bridge_sha256=sha(bridge_data), cef_helper_sha256=sha(helper_data), dock_helper_abi=1)


def download(url, destination, limit):
    descriptor, name = tempfile.mkstemp(prefix=destination.name + '.', suffix='.part', dir=destination.parent)
    temporary = Path(name)
    try:
        with os.fdopen(descriptor, 'wb') as output, urllib.request.urlopen(url, timeout=60) as response:
            if not response.url.startswith('https://'):
                raise ValueError('Insecure archive redirect')
            total = 0
            while chunk := response.read(1024*1024):
                total += len(chunk)
                if total > limit:
                    raise ValueError('Download exceeded its size limit')
                output.write(chunk)
        temporary.replace(destination)
    finally:
        temporary.unlink(missing_ok=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--repository', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--bridge', type=Path, required=True)
    args = parser.parse_args()
    root = args.repository.resolve()
    sys.path.insert(0, str(root / 'cef-source/client_compat/bridge'))
    from verify_launcher_target import target
    version, digest = target(root)
    selected = os.environ.get('KCDMP_LAUNCHER_ARCHIVE')
    if selected:
        archive = Path(selected)
        checksum = Path(str(archive) + '.sha256')
    else:
        cache = root / '.build/official-client'
        cache.mkdir(parents=True, exist_ok=True)
        archive = cache / f'KcdMp-{version}-win-x64.zip'
        checksum = cache / (archive.name + '.sha256')
        base = f'https://github.com/dintech-rappy/kcd-mp-releases/releases/download/v{version}'
        if not checksum.exists():
            download(f'{base}/{checksum.name}', checksum, 4096)
        if not archive.exists():
            download(f'{base}/{archive.name}', archive, 512*1024*1024)
    manifest = prepare(archive, checksum, version, digest, args.bridge,
                       root / 'cef-compat/client_compat/bin/KcdMpCefCompat.dll',
                       args.bridge.parent / 'libKcdMpDockPolicy.dylib')
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(manifest, indent=2) + '\n')
    print(f'Packaged official launcher and CEF target: {version}')


if __name__ == '__main__':
    main()

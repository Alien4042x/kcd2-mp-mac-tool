#!/usr/bin/env python3
"""Compare the supplied DLL to its rebuild, ignoring only PE build timestamps."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import struct
import subprocess
import tempfile

HERE = Path(__file__).resolve().parent

def normalize(data):
    data = bytearray(data)
    pe = struct.unpack_from('<I', data, 60)[0]
    if data[pe:pe+4] != b'PE\0\0':
        raise ValueError('Not a PE image')
    optional = pe+24
    if struct.unpack_from('<H', data, optional)[0] != 0x20b:
        raise ValueError('Expected PE32+')
    data[pe+8:pe+12] = b'\0'*4
    data[optional+64:optional+68] = b'\0'*4
    debug_rva, debug_size = struct.unpack_from('<II', data, optional+112+6*8)
    section_count = struct.unpack_from('<H', data, pe+6)[0]
    optional_size = struct.unpack_from('<H', data, pe+20)[0]
    debug_offset = None
    for index in range(section_count):
        at = optional+optional_size+40*index
        virtual_size, rva, raw_size, raw_offset = struct.unpack_from('<IIII', data, at+8)
        if rva <= debug_rva < rva+max(virtual_size, raw_size):
            debug_offset = raw_offset+debug_rva-rva
    if debug_size:
        if debug_offset is None or debug_size % 28 or debug_offset+debug_size > len(data):
            raise ValueError('Invalid PE debug directory')
        for offset in range(debug_offset, debug_offset+debug_size, 28):
            data[offset+4:offset+8] = b'\0'*4
    return data

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--dll', type=Path,
        default=HERE.parents[1]/'cef-compat/client_compat/bin/KcdMpCefCompat.dll')
    parser.add_argument('--report', type=Path)
    args = parser.parse_args()
    toolchain = Path(os.environ.get('KCDMP_LLVM_MINGW', str(Path.home()/'llvm-mingw'))).expanduser()
    with tempfile.TemporaryDirectory(prefix='kcdmp-release-build-') as stage:
        candidate = Path(stage)/'KcdMpCefCompat.dll'
        subprocess.run([str(toolchain/'bin/x86_64-w64-mingw32-clang++'),
            '-std=c++17', '-O2', '-static', '-shared', '-Wall', '-Wextra', '-Werror',
            str(HERE/'bridge/cef_compat.cpp'), str(HERE/'bridge/cpu_bridge.cpp'),
            '-ld3d12', '-ldxguid', '-lbcrypt', '-o', str(candidate)], check=True)
        supplied = args.dll.read_bytes()
        rebuilt = candidate.read_bytes()
        record = {'shipped_sha256': hashlib.sha256(supplied).hexdigest(),
            'rebuilt_sha256': hashlib.sha256(rebuilt).hexdigest(),
            'binary_identical': supplied == rebuilt,
            'identical_except_pe_build_timestamps_checksum': normalize(supplied) == normalize(rebuilt),
            'shipped_binary_replaced': False, 'game_started': False}
        if args.report:
            args.report.write_text(json.dumps(record, indent=2)+'\n')
        print(json.dumps(record, indent=2))
        if not record['identical_except_pe_build_timestamps_checksum']:
            raise SystemExit('Supplied binary and sources differ beyond PE build metadata')

if __name__ == '__main__':
    main()

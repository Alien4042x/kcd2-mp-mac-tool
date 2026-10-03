#!/usr/bin/env python3
"""Compare a candidate client with a previously reviewed CEF adapter target.

This is a review aid, not permission to install a patch. It fails on changed
instruction flow or referenced data and prints the exact functions reviewed.
"""
import argparse
import hashlib
import json
import re
import struct
import subprocess
from pathlib import Path

READ_FUNCTIONS = (
    'render_info', 'loading_visible', 'loading_covers',
    'set_loading_cover_probe', 'loading_wants_paint',
)


def checked_manifest(path, client):
    manifest = json.loads(path.read_text())
    actual = hashlib.sha256(client.read_bytes()).hexdigest()
    if manifest['sha256'] != actual or manifest['machine'] != 0x8664:
        raise ValueError(f'{client}: hash or AMD64 machine mismatch')
    return manifest


def symbols(nm, client):
    output = subprocess.check_output([nm, str(client)], text=True)
    return sorted({int(parts[0], 16) for row in output.splitlines()
                   if len(parts := row.split()) == 3})


def instructions(objdump, client, start, end):
    output = subprocess.check_output([
        objdump, '-d', '--no-show-raw-insn',
        f'--start-address={start}', f'--stop-address={end}', str(client)
    ], text=True)
    result = []
    for row in output.splitlines():
        match = re.match(r'^[0-9a-f]+:\s+(.*)', row)
        if match:
            result.append(match.group(1).strip())
    return result


def referenced_data(client, address, size=256):
    data = client.read_bytes()
    pe = struct.unpack_from('<I', data, 60)[0]
    count = struct.unpack_from('<H', data, pe + 6)[0]
    optional = struct.unpack_from('<H', data, pe + 20)[0]
    base = struct.unpack_from('<Q', data, pe + 48)[0]
    rva = address - base
    for index in range(count):
        offset = pe + 24 + optional + index * 40
        name = data[offset:offset+8].rstrip(b'\0')
        virtual_size, section_rva, raw_size, raw_offset = struct.unpack_from('<IIII', data, offset + 8)
        if name == b'.rdata' and section_rva <= rva < section_rva + max(virtual_size, raw_size):
            raw = raw_offset + rva - section_rva
            block = data[raw:raw+size]
            string = block.split(b'\0', 1)[0]
            if len(string) >= 4 and all(32 <= byte < 127 for byte in string):
                return ('string', string)
            return ('bytes16', block[:16])
    raise ValueError(f'RVA {rva:#x} is not mapped into .rdata')


def normalize(left, right, old_client, new_client):
    references = re.compile(r'# 0x([0-9a-f]+) <\.rdata\+0x[0-9a-f]+>')
    old_ref, new_ref = references.search(left), references.search(right)
    if bool(old_ref) != bool(new_ref):
        raise ValueError('one instruction changed its .rdata reference')
    if old_ref:
        old_data = referenced_data(old_client, int(old_ref.group(1), 16))
        new_data = referenced_data(new_client, int(new_ref.group(1), 16))
        if old_data != new_data:
            raise ValueError(f'referenced .rdata changed: {old_data!r} -> {new_data!r}')
    def canonical(row):
        row = re.sub(r'0x[0-9a-f]+ <([^>]+)>', r'<\1>', row)
        row = re.sub(r'0x[0-9a-f]+\(%rip\)', '<rip>(%rip)', row)
        if old_ref:
            row = re.sub(r'<\.rdata\+0x[0-9a-f]+>', '<.rdata>', row)
        return row
    return canonical(left), canonical(right), bool(old_ref)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ('previous-client', 'previous-manifest', 'candidate-client', 'candidate-manifest'):
        parser.add_argument('--' + name, required=True, type=Path)
    parser.add_argument('--toolchain', type=Path, default=Path.home() / 'llvm-mingw/bin')
    args = parser.parse_args()
    old_client, new_client = args.previous_client, args.candidate_client
    old = checked_manifest(args.previous_manifest, old_client)
    new = checked_manifest(args.candidate_manifest, new_client)
    if set(old['read_bindings']) != set(new['read_bindings']):
        raise ValueError('read binding names changed')
    if old['image_base'] != new['image_base']:
        raise ValueError('image base changed, review PE mapping manually')
    old_symbols = symbols(str(args.toolchain / 'llvm-nm'), old_client)
    new_symbols = symbols(str(args.toolchain / 'llvm-nm'), new_client)
    objdump = str(args.toolchain / 'llvm-objdump')
    functions = []
    if [entry['name'] for entry in old['patches']] != [entry['name'] for entry in new['patches']]:
        raise ValueError('patch entry set or order changed')
    for before, after in zip(old['patches'], new['patches']):
        if before['section'] != '.text' or after['section'] != '.text':
            raise ValueError(f"{before['name']}: entry moved out of .text")
        functions.append((before['name'], before['rva'], before['function_end'],
                          after['rva'], after['function_end']))
    for name in READ_FUNCTIONS:
        old_start = old['image_base'] + old['read_bindings'][name]
        new_start = new['image_base'] + new['read_bindings'][name]
        old_end = next(address for address in old_symbols if address > old_start)
        new_end = next(address for address in new_symbols if address > new_start)
        functions.append((name, old_start-old['image_base'], old_end-old['image_base'],
                          new_start-new['image_base'], new_end-new['image_base']))
    total_instructions = 0
    data_references = 0
    for name, old_rva, old_end, new_rva, new_end in functions:
        if old_end - old_rva != new_end - new_rva:
            raise ValueError(f'{name}: function size changed')
        previous = instructions(objdump, old_client, old['image_base']+old_rva, old['image_base']+old_end)
        candidate = instructions(objdump, new_client, new['image_base']+new_rva, new['image_base']+new_end)
        if len(previous) != len(candidate):
            raise ValueError(f'{name}: instruction count changed')
        for index, (left, right) in enumerate(zip(previous, candidate)):
            try:
                normalized_old, normalized_new, data_changed_address = normalize(left, right, old_client, new_client)
            except ValueError as error:
                raise ValueError(f'{name} instruction {index}: {error}') from error
            if normalized_old != normalized_new:
                raise ValueError(f'{name} instruction {index}: {left!r} -> {right!r}')
            total_instructions += 1
            data_references += data_changed_address
        print(f'{name}: RVA {old_rva:#x} -> {new_rva:#x}, {len(previous)} instructions match')
    print(f'REVIEW|PASS|{len(functions)} functions|{total_instructions} instructions|'
          f'{data_references} .rdata references checked|candidate {new["sha256"]}')
    print('Static correspondence only. Run isolated guard and game tests before release.')


if __name__ == '__main__':
    main()

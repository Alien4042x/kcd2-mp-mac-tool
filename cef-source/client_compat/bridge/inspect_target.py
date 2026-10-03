#!/usr/bin/env python3
"""Read-only exact-version manifest. RVAs derive from retained binary symbols."""
from pathlib import Path
import hashlib
import json
import os
import struct
import subprocess

BASE = Path(__file__).resolve().parent
CLIENT = Path(os.environ.get('KCDMP_CLIENT_DLL', str(Path.home()/'WineForge/Steam/drive_c/Program Files (x86)/Steam/steamapps/common/KingdomComeDeliverance2/Bin/Win64MasterMasterSteamPGO/KcdMp_client.dll'))).expanduser()
TOOLCHAIN = Path(os.environ.get('KCDMP_LLVM_MINGW', str(Path.home()/'llvm-mingw'))).expanduser()
EXPECTED_SHA = '953ea2ee442f81f79840b0cf6b9d4c3ba26c6d91e630e9980a4788a3d09868d1'
SYMBOLS = {
    'frames_open':'_ZN5KcdMp3web6frames4openE5_LUIDRNSt7__cxx1112basic_stringIcSt11char_traitsIcESaIcEEE',
    'frames_paint':'_ZN5KcdMp3web6frames9paint_cpuEPKvii',
    'popup_paint':'_ZN5KcdMp3web6frames15paint_popup_cpuEPKvii',
    'popup_rect':'_ZN5KcdMp3web6frames10popup_rectEiiii',
    'popup_show':'_ZN5KcdMp3web6frames10popup_showEb',
    'frames_latest':'_ZN5KcdMp3web6frames6latestERNS1_9PublishedE',
    'record':'_ZN5KcdMp3web10compositor12_GLOBAL__N_16recordEP25ID3D12GraphicsCommandListjj',
    'before_submit':'_ZN5KcdMp3web10compositor12_GLOBAL__N_113before_submitEP18ID3D12CommandQueue',
    'after_submit':'_ZN5KcdMp3web10compositor12_GLOBAL__N_112after_submitEP18ID3D12CommandQueue',
    'renderer_reset':'_ZN5KcdMp3web10compositor12_GLOBAL__N_114renderer_resetEv',
}
READ_SYMBOLS = {
    'render_info':'_ZN5KcdMp5hooks11render_infoEv',
    'loading_visible':'_ZN5KcdMp2ui14loading_screen7visibleEv',
    'loading_covers':'_ZN5KcdMp2ui14loading_screen14web_covers_nowEv',
    'enabled':'_ZN5KcdMp3web10compositor12_GLOBAL__N_19g_enabledE',
    'shown':'_ZN5KcdMp3web10compositor12_GLOBAL__N_17g_shownE',
    'pipeline_failed':'_ZN5KcdMp3web10compositor12_GLOBAL__N_117g_pipeline_failedE',
    'frames_drawn':'_ZN5KcdMp3web10compositor12_GLOBAL__N_18g_framesE',
    'frame_device':'_ZN5KcdMp3web6frames12_GLOBAL__N_18g_deviceE',
}

def main():
    b = CLIENT.read_bytes()
    sha = hashlib.sha256(b).hexdigest()
    if sha != EXPECTED_SHA: raise SystemExit('Refusing unsupported client SHA-256')
    pe = struct.unpack_from('<I', b, 60)[0]
    machine, count, timestamp = struct.unpack_from('<HHI', b, pe + 4)
    optional = struct.unpack_from('<H', b, pe+20)[0]
    image_base = struct.unpack_from('<Q', b, pe+24+24)[0]
    image_size = struct.unpack_from('<I', b, pe+24+56)[0]
    sections = []
    for i in range(count):
        o = pe+24+optional+40*i
        name = b[o:o+8].rstrip(b'\0').decode()
        virtual_size, rva, raw_size, raw_offset = struct.unpack_from('<IIII', b, o+8)
        sections.append((name, rva, max(virtual_size, raw_size), raw_offset))
    text = subprocess.check_output([str(TOOLCHAIN/'bin/llvm-nm'), str(CLIENT)], text=True)
    symbols = {row.split(maxsplit=2)[2]: int(row.split()[0],16) for row in text.splitlines() if len(row.split()) == 3}
    addresses = sorted(set(symbols.values()))
    fixed = b.find(bytes.fromhex('bd04effe'))
    version = None
    if fixed >= 0:
        ms, ls = struct.unpack_from('<II',b,fixed+8)
        version = '.'.join(map(str,[ms>>16,ms&65535,ls>>16,ls&65535]))
    entries = []
    for label, symbol in SYMBOLS.items():
        address = symbols[symbol]; rva = address-image_base
        name, va, _, raw = next(s for s in sections if s[1] <= rva < s[1]+s[2])
        offset = raw+rva-va
        original = b[offset:offset+14]
        next_address = next(a for a in addresses if a > address)
        entries.append(dict(name=label,symbol=symbol,rva=rva,raw_offset=offset,section=name,
            original=original.hex(),signature_occurrences=b.count(original),function_end=next_address-image_base,
            replacement='ff2500000000 + uint64 little-endian helper entry VA',length=14))
    manifest = dict(product='KCD:MP 0.37.0', file_version=version, machine=machine,
        image_base=image_base,image_size=image_size,timestamp=timestamp,sha256=sha,
        process_path='C:\\Program Files (x86)\\Steam\\steamapps\\common\\KingdomComeDeliverance2\\Bin\\Win64MasterMasterSteamPGO\\KingdomCome.exe',
        module_name='KcdMp_client.dll',client_disk_unchanged=True,patches=entries,
        read_bindings={name:symbols[s]-image_base for name,s in READ_SYMBOLS.items()})
    (BASE/'target-0.37.0.json').write_text(json.dumps(manifest,indent=2)+'\n')
    lines=['// Generated from the exact supported client. Never hand-update RVAs.', '#pragma once', '#include <cstdint>', 'namespace target {',
        f'constexpr uint32_t image_size = {image_size}u;', f'constexpr uint32_t timestamp = {timestamp}u;',
        f'constexpr char client_sha[] = "{sha}";',
        f'constexpr wchar_t process_path[] = LR"({manifest["process_path"]})";',
        'struct Entry { const char *name; uint32_t rva, end; unsigned char bytes[14]; };', 'constexpr Entry entries[] = {']
    for item in entries:
        array=', '.join('0x'+item['original'][i:i+2] for i in range(0,28,2))
        lines.append(f'    {{"{item["name"]}", 0x{item["rva"]:x}, 0x{item["function_end"]:x}, {{{array}}}}},')
    lines += ['};']
    for name, rva in manifest['read_bindings'].items(): lines.append(f'constexpr uint32_t {name} = 0x{rva:x};')
    lines += ['}']
    (BASE/'target-0.37.0.h').write_text('\n'.join(lines)+'\n')
    print(f'TARGET|AMD64|SHA256={sha}|patches={len(entries)}|version={version}')

if __name__ == '__main__': main()

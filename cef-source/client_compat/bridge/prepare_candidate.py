#!/usr/bin/env python3
"""Prepare an exact-version CEF candidate when reviewed functions are unchanged.

This only produces review files. It never enables, signs, or publishes a helper.
Any changed instruction, data reference, function boundary, or ambiguous anchor
stops the port so a developer can investigate the new client.
"""

import argparse
import hashlib
import json
import re
import struct
from pathlib import Path

from review_target import instructions, referenced_data

PATCH_GROUPS = {
    "frames": {"frames_open", "frames_paint", "popup_paint", "popup_rect", "popup_show", "frames_latest"},
    "compositor": {"record", "before_submit", "after_submit", "renderer_reset"},
}
DIRECT_READS = ("render_info", "loading_visible", "loading_covers")
OTHER_READS = ("set_loading_cover_probe", "loading_wants_paint")
WANTS_PAINT_PATTERN = re.compile(rb"\x0f\xb6\x05....\x84\xc0\x0f\x95\xc0\xc3", re.DOTALL)


def require(condition, reason):
    if not condition:
        raise ValueError(reason)


class PE:
    def __init__(self, path):
        self.path = path
        self.data = path.read_bytes()
        require(self.data[:2] == b"MZ", f"{path}: missing MZ header")
        pe = struct.unpack_from("<I", self.data, 60)[0]
        require(self.data[pe:pe + 4] == b"PE\0\0", f"{path}: missing PE header")
        self.machine, count, self.timestamp = struct.unpack_from("<HHI", self.data, pe + 4)
        optional = struct.unpack_from("<H", self.data, pe + 20)[0]
        require(self.machine == 0x8664 and struct.unpack_from("<H", self.data, pe + 24)[0] == 0x20b,
                f"{path}: expected AMD64 PE32+")
        self.image_base = struct.unpack_from("<Q", self.data, pe + 48)[0]
        self.image_size = struct.unpack_from("<I", self.data, pe + 24 + 56)[0]
        self.sha256 = hashlib.sha256(self.data).hexdigest()
        self.sections = {}
        for index in range(count):
            at = pe + 24 + optional + index * 40
            name = self.data[at:at + 8].rstrip(b"\0").decode("ascii")
            virtual_size, rva, raw_size, raw = struct.unpack_from("<IIII", self.data, at + 8)
            require(raw + raw_size <= len(self.data), f"{path}: {name} exceeds file")
            self.sections[name] = (rva, max(virtual_size, raw_size), raw, raw_size)
        require(".text" in self.sections and ".pdata" in self.sections and ".rdata" in self.sections,
                f"{path}: missing required PE section")
        base, _, raw, size = self.sections[".pdata"]
        self.functions = {start: end for start, end, _ in
                          struct.iter_unpack("<III", self.data[raw:raw + size // 12 * 12])
                          if start and end > start and end <= self.image_size}
        marker = self.data.find(bytes.fromhex("bd04effe"))
        require(marker >= 0, f"{path}: version resource not found")
        ms, ls = struct.unpack_from("<II", self.data, marker + 8)
        self.version = ".".join(map(str, (ms >> 16, ms & 65535, ls >> 16, ls & 65535)))

    def section_at(self, rva):
        for name, (start, size, _, _) in self.sections.items():
            if start <= rva < start + size:
                return name
        raise ValueError(f"{self.path}: RVA {rva:#x} is outside mapped sections")

    def raw_offset(self, rva, length):
        name = self.section_at(rva)
        start, _, raw, raw_size = self.sections[name]
        offset = raw + rva - start
        require(offset + length <= raw + raw_size, f"{self.path}: RVA {rva:#x} exceeds raw {name}")
        return name, offset

    def bytes_at(self, rva, length):
        _, offset = self.raw_offset(rva, length)
        return self.data[offset:offset + length]

    def unique_anchor(self, original):
        require(self.data.count(original) == 1, f"{self.path}: anchor is missing or ambiguous")
        offset = self.data.index(original)
        for name, (start, _, raw, raw_size) in self.sections.items():
            if raw <= offset and offset + len(original) <= raw + raw_size:
                require(name == ".text", f"{self.path}: anchor moved out of .text")
                return start + offset - raw
        raise ValueError(f"{self.path}: anchor is outside sections")


def canonical(row):
    row = re.sub(r"0x[0-9a-f]+\(%rip\)", "<RIP>(%rip)", row)
    row = re.sub(r"# 0x[0-9a-f]+(?: <[^>]+>)?", " # <REF>", row)
    return re.sub(r"0x[0-9a-f]+ <[^>]+>", "<TARGET>", row)


def address(row, pattern):
    match = re.search(pattern, row)
    return int(match.group(1), 16) if match else None


def compare_function(name, old, new, old_start, old_end, new_start, new_end,
                     objdump, branches, data_targets, totals):
    require(old_end - old_start == new_end - new_start, f"{name}: function size changed")
    before = instructions(str(objdump), old.path, old.image_base + old_start, old.image_base + old_end)
    after = instructions(str(objdump), new.path, new.image_base + new_start, new.image_base + new_end)
    require(len(before) == len(after) and before, f"{name}: instruction count changed")
    for index, (left, right) in enumerate(zip(before, after)):
        require(canonical(left) == canonical(right), f"{name}: instruction {index} changed: {left!r} -> {right!r}")
        branch = r"^(?:callq|jmp|j\w+)\s+0x([0-9a-f]+)"
        old_branch, new_branch = address(left, branch), address(right, branch)
        require((old_branch is None) == (new_branch is None), f"{name}: branch {index} changed")
        if old_branch is not None:
            old_target, new_target = old_branch - old.image_base, new_branch - new.image_base
            if old_start <= old_target < old_end:
                require(new_target - old_target == new_start - old_start,
                        f"{name}: internal branch {index} changed")
                totals["internal_branches"] += 1
            else:
                previous = branches.setdefault(old_target, new_target)
                require(previous == new_target, f"{name}: external branch target is inconsistent")
        old_ref, new_ref = address(left, r"# 0x([0-9a-f]+)"), address(right, r"# 0x([0-9a-f]+)")
        require((old_ref is None) == (new_ref is None), f"{name}: data reference {index} changed")
        if old_ref is not None:
            old_rva, new_rva = old_ref - old.image_base, new_ref - new.image_base
            previous = data_targets.setdefault(old_rva, new_rva)
            require(previous == new_rva, f"{name}: data reference target is inconsistent")
            if old.section_at(old_rva) == ".rdata":
                require(new.section_at(new_rva) == ".rdata", f"{name}: read-only data moved")
                require(referenced_data(old.path, old_ref) == referenced_data(new.path, new_ref),
                        f"{name}: referenced read-only data changed")
                totals["read_only_refs"] += 1
        totals["instructions"] += 1
    totals["functions"] += 1


def render_header(manifest):
    lines = [f'// Derived from the exact reviewed {manifest["file_version"].removesuffix(".0")} client. Never hand-update RVAs.',
             "#pragma once", "#include <cstdint>", "namespace target {",
             f'constexpr uint32_t image_size = {manifest["image_size"]}u;',
             f'constexpr uint32_t timestamp = {manifest["timestamp"]}u;',
             f'constexpr char client_sha[] = "{manifest["sha256"]}";',
             f'constexpr wchar_t process_path[] = LR"({manifest["process_path"]})";',
             "struct Entry { const char *name; uint32_t rva, end; unsigned char bytes[14]; };",
             "constexpr Entry entries[] = {"]
    for item in manifest["patches"]:
        raw = item["original"]
        values = ", ".join("0x" + raw[i:i + 2] for i in range(0, 28, 2))
        lines.append(f'    {{"{item["name"]}", 0x{item["rva"]:x}, 0x{item["function_end"]:x}, {{{values}}}}},')
    lines.append("};")
    for name, rva in manifest["read_bindings"].items():
        lines.append(f"constexpr uint32_t {name} = 0x{rva:x};")
    lines += ["struct ReadEntry { const char *name; uint32_t rva, length; unsigned char bytes[13]; };",
              "constexpr ReadEntry read_entries[] = {"]
    for item in manifest["read_checks"]:
        raw = item["original"]
        values = ", ".join("0x" + raw[i:i + 2] for i in range(0, len(raw), 2))
        lines.append(f'    {{"{item["name"]}", 0x{item["rva"]:x}, {item["length"]}u, {{{values}}}}},')
    return "\n".join(lines + ["};", "}", ""])


def prepare(args):
    old_manifest = json.loads(args.previous_manifest.read_text())
    old, new = PE(args.previous_client), PE(args.candidate_client)
    require(old.sha256 == old_manifest["sha256"], "Previous client does not match the reviewed manifest")
    require(old.image_base == new.image_base, "PE image base changed")
    require(re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+", args.version) is not None,
            "Candidate version is invalid")
    require(new.version == args.version + ".0", "Candidate file version differs from release tag")
    require(old.version == old_manifest["file_version"], "Previous file version differs from manifest")
    entries = {item["name"]: item for item in old_manifest["patches"]}
    require(set(entries) == PATCH_GROUPS["frames"] | PATCH_GROUPS["compositor"],
            "Reviewed patch entry set changed")
    shifts = {}
    for group, anchor in (("frames", "popup_rect"), ("compositor", "renderer_reset")):
        item = entries[anchor]
        original = bytes.fromhex(item["original"])
        require(old.unique_anchor(original) == item["rva"], f"{anchor}: old anchor mismatch")
        shifts[group] = new.unique_anchor(original) - item["rva"]
    branches, data_targets = {}, {}
    totals = {"functions": 0, "instructions": 0, "internal_branches": 0, "read_only_refs": 0}
    patches = []
    for item in old_manifest["patches"]:
        group = next(group for group, names in PATCH_GROUPS.items() if item["name"] in names)
        new_rva = item["rva"] + shifts[group]
        require(old.functions[item["rva"]] - item["rva"] == new.functions.get(new_rva, -1) - new_rva,
                f'{item["name"]}: unwind function size changed')
        end = item["function_end"] + shifts[group]
        compare_function(item["name"], old, new, item["rva"], item["function_end"],
                         new_rva, end, args.objdump, branches, data_targets, totals)
        section, offset = new.raw_offset(new_rva, 14)
        require(section == ".text", f'{item["name"]}: entry moved out of .text')
        original = new.bytes_at(new_rva, 14)
        patches.append({**item, "rva": new_rva, "function_end": end, "raw_offset": offset,
                        "original": original.hex(), "signature_occurrences": new.data.count(original)})
    old_bindings = old_manifest["read_bindings"]
    reads = {name: branches[old_bindings[name]] for name in DIRECT_READS}
    reads["set_loading_cover_probe"] = (reads["loading_covers"] + old_bindings["set_loading_cover_probe"]
                                          - old_bindings["loading_covers"])
    for name in DIRECT_READS + ("set_loading_cover_probe",):
        old_rva, new_rva = old_bindings[name], reads[name]
        require(old_rva in old.functions and new_rva in new.functions, f"{name}: function entry missing")
        compare_function(name, old, new, old_rva, old.functions[old_rva], new_rva,
                         new.functions[new_rva], args.objdump, branches, data_targets, totals)
    reads["loading_cover_probe"] = data_targets[old_bindings["loading_cover_probe"]]
    # This flag shares the reviewed data layout with g_enabled. Refuse a port if it moves.
    flag = data_targets[old_bindings["enabled"]] + (old_bindings["loading_wants_paint_flag"]
                                                    - old_bindings["enabled"])
    require(new.section_at(flag) == old.section_at(old_bindings["loading_wants_paint_flag"])
            and new.section_at(flag) in (".data", ".bss"),
            "Loading paint flag moved out of writable data")
    text_rva, _, text_raw, text_size = new.sections[".text"]
    candidates = []
    for match in WANTS_PAINT_PATTERN.finditer(new.data[text_raw:text_raw + text_size]):
        rva = text_rva + match.start()
        displacement = struct.unpack_from("<i", new.data, text_raw + match.start() + 3)[0]
        if rva + 7 + displacement == flag and rva in new.functions:
            candidates.append(rva)
    require(len(candidates) == 1, "Loading paint function is missing or ambiguous")
    reads["loading_wants_paint"] = candidates[0]
    old_rva, new_rva = old_bindings["loading_wants_paint"], reads["loading_wants_paint"]
    compare_function("loading_wants_paint", old, new, old_rva, old.functions[old_rva],
                     new_rva, new.functions[new_rva], args.objdump, branches, data_targets, totals)
    reads["loading_wants_paint_flag"] = data_targets[old_bindings["loading_wants_paint_flag"]]
    for name in old_bindings:
        if name not in reads:
            reads[name] = data_targets[old_bindings[name]]
    require(set(reads) == set(old_bindings), "A read binding was not independently mapped")
    reads = {name: reads[name] for name in old_bindings}
    for name in ("enabled", "shown", "pipeline_failed", "frames_drawn", "frame_device",
                 "loading_cover_probe", "loading_wants_paint_flag"):
        require(new.section_at(reads[name]) == old.section_at(old_bindings[name])
                and new.section_at(reads[name]) in (".data", ".bss"),
                f"{name}: binding moved out of writable data")
    checks = []
    for item in old_manifest["read_checks"]:
        new_rva = reads[item["name"]]
        section, offset = new.raw_offset(new_rva, item["length"])
        require(section == ".text", f'{item["name"]}: read check moved out of code')
        checks.append({**item, "rva": new_rva, "raw_offset": offset,
                       "original": new.bytes_at(new_rva, item["length"]).hex()})
    manifest = {**old_manifest, "product": f"KCD:MP {args.version}",
                "file_version": new.version, "machine": new.machine,
                "image_base": new.image_base, "image_size": new.image_size,
                "timestamp": new.timestamp, "sha256": new.sha256,
                "patches": patches, "read_bindings": reads, "read_checks": checks}
    args.output_dir.mkdir(parents=True, exist_ok=True)
    (args.output_dir / f"target-{args.version}.json").write_text(json.dumps(manifest, indent=2) + "\n")
    (args.output_dir / f"target-{args.version}.h").write_text(render_header(manifest))
    summary = {"version": args.version, "client_sha256": new.sha256,
               "anchors": {name: f"{shift:+#x}" for name, shift in shifts.items()},
               "external_branches": len(branches), "data_targets": len(data_targets), **totals,
               "live_game_verified": False}
    (args.output_dir / f"candidate-{args.version}.json").write_text(json.dumps(summary, indent=2) + "\n")
    print(json.dumps(summary, indent=2))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--previous-client", type=Path, required=True)
    parser.add_argument("--previous-manifest", type=Path, required=True)
    parser.add_argument("--candidate-client", type=Path, required=True)
    parser.add_argument("--version", required=True)
    parser.add_argument("--output-dir", type=Path, required=True)
    parser.add_argument("--objdump", type=Path, default=Path.home() / "llvm-mingw/bin/llvm-objdump")
    args = parser.parse_args()
    try:
        prepare(args)
    except (ValueError, KeyError, IndexError, struct.error) as error:
        parser.exit(1, f"CEF candidate refused: {error}\n")


if __name__ == "__main__":
    main()

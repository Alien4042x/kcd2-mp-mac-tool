#!/usr/bin/env python3
"""Stage a reviewed-by-script CEF candidate in a disposable CI checkout.

This does not commit, sign, or publish the candidate. The source checkout must
still contain the exact previously reviewed client and helper selection.
"""

import argparse
import json
import re
import shutil
from pathlib import Path

from verify_launcher_target import target, verify


def replace_one(text, old, new, label):
    if text.count(old) != 1:
        raise ValueError(f"Expected exactly one previous {label}")
    return text.replace(old, new)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--candidate-dir", type=Path, required=True)
    parser.add_argument("--version", required=True)
    parser.add_argument("--repository", type=Path, default=Path(__file__).resolve().parents[3])
    args = parser.parse_args()
    if not re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+", args.version):
        parser.error("Invalid version")
    root = args.repository.resolve()
    bridge = root / "cef-source/client_compat/bridge"
    verify(root)
    previous_version, _ = target(root)
    guard = (bridge / "patch_guard.h").read_text()
    candidate = json.loads((args.candidate_dir / f"target-{args.version}.json").read_text())
    summary = json.loads((args.candidate_dir / f"candidate-{args.version}.json").read_text())
    if args.version == previous_version:
        parser.error("Candidate version must differ from the current target")
    if candidate["sha256"] != summary["client_sha256"] or candidate["file_version"] != args.version + ".0":
        parser.error("Candidate manifest and summary differ")
    if summary["live_game_verified"] is not False:
        parser.error("Candidate summary must explicitly mark live game as unverified")
    guard = replace_one(guard, f'#include "target-{previous_version}.h"',
                        f'#include "target-{args.version}.h"', "patch target")
    for suffix in ("json", "h"):
        shutil.copy2(args.candidate_dir / f"target-{args.version}.{suffix}", bridge)
    (bridge / "patch_guard.h").write_text(guard)
    verify(root, write=True)
    print(f"Staged KCD:MP {args.version} CEF candidate without committing it")


if __name__ == "__main__":
    main()

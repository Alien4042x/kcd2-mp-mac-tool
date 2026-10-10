#!/usr/bin/env python3
"""Generate and verify the launcher's exact CEF client version and SHA-256."""

import argparse
import json
import re
from pathlib import Path


def require_one(pattern: str, source: str, label: str) -> str:
    matches = re.findall(pattern, source)
    if len(matches) != 1:
        raise ValueError(f"Expected exactly one {label}")
    return matches[0]


def target(root: Path) -> tuple[str, str]:
    bridge = root / "cef-source/client_compat/bridge"
    guard = (bridge / "patch_guard.h").read_text()
    version = require_one(r'#include "target-([0-9]+\.[0-9]+\.[0-9]+)\.h"',
                          guard, "selected CEF target")
    manifest = json.loads((bridge / f"target-{version}.json").read_text())
    digest = manifest["sha256"]
    if not isinstance(digest, str) or not re.fullmatch(r"[0-9a-f]{64}", digest):
        raise ValueError("Target client SHA-256 must contain 64 lowercase hex digits")
    if manifest["file_version"] != version + ".0":
        raise ValueError("Selected CEF target version differs from its manifest")
    header = (bridge / f"target-{version}.h").read_text()
    header_digest = require_one(r'constexpr char client_sha\[\] = "([0-9a-f]+)";',
                                header, "helper client SHA-256")
    if header_digest != digest:
        raise ValueError("CEF helper target header differs from the target manifest")
    return version, digest


def generated_source(version: str, digest: str) -> str:
    return (
        "// Generated from the selected exact CEF target. Do not edit.\n"
        "enum CEFClientTarget {\n"
        f'    static let version = "{version}"\n'
        f'    static let sha256 = "{digest}"\n'
        "}\n"
    )


def verify(root: Path, write: bool = False) -> None:
    version, digest = target(root)
    destination = root / "CEFClientTarget.swift"
    expected = generated_source(version, digest)
    if write and (not destination.exists() or destination.read_text() != expected):
        destination.write_text(expected)
    if not destination.exists() or destination.read_text() != expected:
        raise ValueError("Generated Swift target differs from the selected CEF target")
    source = (root / "CEFLauncher.swift").read_text()
    if not re.search(r'static let supportedVersion = CEFClientTarget\.version\b', source):
        raise ValueError("Launcher is not using the generated target version")
    if not re.search(r'static let supportedClientHash = CEFClientTarget\.sha256\b', source):
        raise ValueError("Launcher is not using the generated client SHA-256")
    print(f"Launcher and CEF helper target match KCD:MP {version}: {digest}")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repository", type=Path, default=Path(__file__).resolve().parents[3])
    parser.add_argument("--write", action="store_true", help="Regenerate the Swift file from the selected target")
    args = parser.parse_args()
    try:
        verify(args.repository.resolve(), write=args.write)
    except (OSError, KeyError, ValueError, TypeError) as error:
        parser.exit(1, f"CEF build refused: {error}\n")

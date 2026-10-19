#!/usr/bin/env python3
"""Select a Mac CEF build only when its upstream ZIP is not already released."""

import argparse
import json
from pathlib import Path
import re


TAG = re.compile(r"v(\d+)\.(\d+)\.(\d+)")
TARGET = re.compile(r'#include "target-(\d+\.\d+\.\d+)\.h"')


def read_json(path):
    try:
        return json.loads(path.read_text())
    except (OSError, UnicodeError, json.JSONDecodeError) as error:
        raise ValueError(f"Cannot read valid JSON from {path}: {error}") from error


def current_version(header):
    try:
        matches = TARGET.findall(header.read_text())
    except (OSError, UnicodeError) as error:
        raise ValueError(f"Cannot read current CEF target from {header}: {error}") from error
    if len(matches) != 1:
        raise ValueError("Expected exactly one current CEF target")
    return matches[0]


def select(upstream, release_pages, current):
    if not isinstance(upstream, dict) or not isinstance(upstream.get("tag_name"), str):
        raise ValueError("Upstream release is missing a tag name")
    tag = upstream["tag_name"]
    match = TAG.fullmatch(tag)
    if not match:
        raise ValueError(f"Unexpected upstream release tag: {tag!r}")
    version = ".".join(match.groups())
    if not isinstance(release_pages, list):
        raise ValueError("Repository releases must be a JSON array")
    if release_pages and all(isinstance(item, dict) for item in release_pages):
        release_pages = [release_pages]
    expected_asset = f"KCDMP-Mac-{tag}.zip"
    found = False
    for page in release_pages:
        if not isinstance(page, list):
            raise ValueError("A repository releases page is not a JSON array")
        for release in page:
            if not isinstance(release, dict) or not isinstance(release.get("assets"), list):
                raise ValueError("A repository release is missing its assets array")
            for asset in release["assets"]:
                if not isinstance(asset, dict):
                    raise ValueError("A release asset is not a JSON object")
                name, state, size = (asset.get(key) for key in ("name", "state", "size"))
                if not isinstance(name, str) or not isinstance(state, str):
                    raise ValueError("A release asset is missing its name or state")
                if not isinstance(size, int) or isinstance(size, bool) or size < 0:
                    raise ValueError("A release asset has an invalid size")
                if name == expected_asset and state == "uploaded" and size > 0:
                    found = True
    if found:
        return tag, version, "false"
    if tuple(map(int, match.groups())) < tuple(map(int, current.split("."))):
        raise ValueError("Official latest version is older than the selected CEF target")
    return tag, version, "current" if version == current else "candidate"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--upstream", type=Path, required=True)
    parser.add_argument("--releases", type=Path, required=True)
    parser.add_argument("--current-header", type=Path, required=True)
    parser.add_argument("--github-output", type=Path, required=True)
    args = parser.parse_args()
    try:
        tag, version, build = select(
            read_json(args.upstream), read_json(args.releases),
            current_version(args.current_header))
        with args.github_output.open("a") as output:
            output.write(f"tag={tag}\nversion={version}\nbuild={build}\n")
    except (OSError, ValueError) as error:
        parser.error(str(error))
    print(f"KCD:MP {tag}: build={build}")


if __name__ == "__main__":
    main()

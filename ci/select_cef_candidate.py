#!/usr/bin/env python3
"""Select the newest Windows client with no existing Mac ZIP."""

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


def newest_client(upstream_pages):
    if not isinstance(upstream_pages, list):
        raise ValueError("Upstream releases must be an array of pages")
    stable = []
    for page in upstream_pages:
        if not isinstance(page, list):
            raise ValueError("An upstream releases page is not an array")
        for release in page:
            if not isinstance(release, dict):
                raise ValueError("An upstream release is not an object")
            if not isinstance(release.get("draft"), bool) or not isinstance(
                    release.get("prerelease"), bool):
                raise ValueError("An upstream release is missing its draft status")
            if release["draft"] or release["prerelease"]:
                continue
            tag = release.get("tag_name")
            match = TAG.fullmatch(tag) if isinstance(tag, str) else None
            if not match:
                raise ValueError(f"Unexpected upstream release tag: {tag!r}")
            stable.append((tuple(map(int, match.groups())), tag, release))
    if not stable:
        raise ValueError("No stable upstream releases found")
    for parts, tag, release in sorted(stable, key=lambda item: item[0], reverse=True):
        version = tag[1:]
        assets = release.get("assets")
        if not isinstance(assets, list) or not assets:
            raise ValueError(f"Upstream {tag} has no assets")
        by_name = {}
        for asset in assets:
            if not isinstance(asset, dict):
                raise ValueError(f"Upstream {tag} has an invalid asset")
            name, state, size = (asset.get(key) for key in ("name", "state", "size"))
            if not isinstance(name, str) or not isinstance(state, str):
                raise ValueError(f"Upstream {tag} has incomplete asset metadata")
            if not isinstance(size, int) or isinstance(size, bool) or size <= 0:
                raise ValueError(f"Upstream {tag} has an invalid asset size")
            if name in by_name:
                raise ValueError(f"Upstream {tag} has duplicate asset {name}")
            by_name[name] = state
        client = f"KcdMp-{version}-win-x64.zip"
        server = f"KcdMp-server-{version}.zip"
        if client in by_name or f"{client}.sha256" in by_name:
            if by_name.get(client) == by_name.get(f"{client}.sha256") == "uploaded":
                return tag, version
            raise ValueError(f"Upstream {tag} has an incomplete Windows client")
        if by_name.get(server) == by_name.get(f"{server}.sha256") == "uploaded":
            continue
        raise ValueError(f"Upstream {tag} has neither a Windows client nor a complete server-only release")
    raise ValueError("No stable upstream Windows client found")


def select(upstream_pages, release_pages, current):
    tag, version = newest_client(upstream_pages)
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
                if name == expected_asset:
                    if state != "uploaded" or size == 0:
                        raise ValueError(f"Mac ZIP {expected_asset} is incomplete")
                    found = True
    if found:
        return tag, version, "false"
    if tuple(map(int, version.split("."))) < tuple(map(int, current.split("."))):
        raise ValueError("Official latest client is older than the selected CEF target")
    return tag, version, "current" if version == current else "candidate"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--upstream-releases", type=Path, required=True)
    parser.add_argument("--releases", type=Path, required=True)
    parser.add_argument("--current-header", type=Path, required=True)
    parser.add_argument("--github-output", type=Path, required=True)
    args = parser.parse_args()
    try:
        tag, version, build = select(
            read_json(args.upstream_releases), read_json(args.releases),
            current_version(args.current_header))
        with args.github_output.open("a") as output:
            output.write(f"tag={tag}\nversion={version}\nbuild={build}\n")
    except (OSError, ValueError) as error:
        parser.error(str(error))
    print(f"KCD:MP latest Windows client {tag}: build={build}")


if __name__ == "__main__":
    main()

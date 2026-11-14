#!/usr/bin/env python3
"""Fetch exact upstream build inputs. Never fetch dependencies during a live run."""
import argparse
import hashlib
import io
import tarfile
import urllib.request
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent / ".deps"
REVISION = "3ab4b5d722438fc8a13e6ca830c5e2372d19a01d"
INPUTS = {
    "webview2.nupkg": ("https://api.nuget.org/v3-flatcontainer/microsoft.web.webview2/1.0.4314.35/microsoft.web.webview2.1.0.4314.35.nupkg", "90778deb1b77e36292828b4b5833c9255c27533f40e0ddd55891ae718944edc4"),
    "webview.tar.gz": (f"https://codeload.github.com/webview/webview/tar.gz/{REVISION}", "3668dca249ce182803fe886c9c9e8e27d2c278a52a647198b947ed9d415019d5"),
    "json.hpp": ("https://raw.githubusercontent.com/nlohmann/json/v3.11.3/single_include/nlohmann/json.hpp", "9bea4c8066ef4a1c206b2be5a36302f8926f7fdc6087af5d20b417d0cf103ea6"),
}
EXTRACTED = {
    "WebView2.h": "4e47763725f507235e8a12f35b9f41d7e348586153414c39fc1e9108875c181f",
    f"webview-{REVISION}/core/include/webview/webview.h": "b1ff6e11431d031e5f7917e5301f4bcdf3910a2763a0720abfd291994eee7f7b",
    f"webview-{REVISION}/compatibility/mingw/include/EventToken.h": "d6305bb8c2c00ddf1ecf8bd9827411318c139ea8d2c8e7592bbe458d1eedd506",
}


def verify(data, expected, name):
    if hashlib.sha256(data).hexdigest() != expected:
        raise ValueError("Dependency hash mismatch: " + name)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--verify", action="store_true", help="Read-only verification of already prepared inputs")
    args = parser.parse_args()
    if not args.verify:
        ROOT.mkdir(parents=True, exist_ok=True)
    for name, (url, digest) in INPUTS.items():
        path = ROOT / name
        if not path.exists():
            if args.verify:
                raise FileNotFoundError(f"Missing {name}. Run python3 {__file__} first.")
            with urllib.request.urlopen(url, timeout=60) as response:
                if not response.url.startswith("https://"):
                    raise ValueError("Insecure redirect")
                data = response.read(50 * 1024 * 1024 + 1)
            if len(data) > 50 * 1024 * 1024:
                raise ValueError("Dependency exceeded size limit")
            verify(data, digest, name)
            with path.open("xb") as output:
                output.write(data)
        verify(path.read_bytes(), digest, name)
    if not args.verify:
        with zipfile.ZipFile(ROOT / "webview2.nupkg") as package:
            data = package.read("build/native/include/WebView2.h")
            verify(data, EXTRACTED["WebView2.h"], "WebView2.h")
            (ROOT / "WebView2.h").write_bytes(data)
            (ROOT / "Microsoft-WebView2-LICENSE.txt").write_bytes(package.read("LICENSE.txt"))
        with tarfile.open(ROOT / "webview.tar.gz") as package:
            for name, digest in EXTRACTED.items():
                if name == "WebView2.h":
                    continue
                member = package.getmember(name)
                if not member.isfile():
                    raise ValueError("Expected regular source file")
                stream = package.extractfile(member)
                if stream is None:
                    raise ValueError("Could not read source member")
                data = stream.read()
                verify(data, digest, name)
                path = ROOT / name
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_bytes(data)
    for name, digest in EXTRACTED.items():
        verify((ROOT / name).read_bytes(), digest, name)
    print("Pinned dependency hashes verified")


if __name__ == "__main__":
    main()

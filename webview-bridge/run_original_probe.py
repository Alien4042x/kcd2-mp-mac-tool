#!/usr/bin/env python3
"""One bounded view-only test, with exclusive staging and hash-checked cleanup."""
import argparse
import contextlib
import hashlib
import json
from pathlib import Path
import subprocess
import re

ORIGINALS = ("KcdMp_launcher.exe", "KcdMp_client.dll", "ui/launcher.html")


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


@contextlib.contextmanager
def staged_loader(game, loader, expected_launcher):
    baseline = {name: digest(game / name) for name in ORIGINALS}
    if baseline["KcdMp_launcher.exe"] != expected_launcher:
        raise ValueError("Launcher hash changed. Refusing an unreviewed target.")
    data = loader.read_bytes()
    if not data.startswith(b"MZ"):
        raise ValueError("Loader is not a PE file")
    target = game / "WebView2Loader.dll"
    loader_hash = hashlib.sha256(data).hexdigest()
    record = {"originals": baseline, "loader_sha256": loader_hash, "loader_removed": False}
    with target.open("xb") as output:
        try:
            output.write(data)
        except BaseException:
            target.unlink()
            raise
    try:
        if digest(target) != loader_hash:
            raise ValueError("Staged loader verification failed")
        yield record
    finally:
        if target.exists():
            if digest(target) != loader_hash:
                raise ValueError("Staged loader was replaced. Refusing to remove a different file.")
            target.unlink()
        record["loader_removed"] = True
        record["unchanged_originals"] = {name: digest(game / name) == value for name, value in baseline.items()}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--launcher", type=Path, required=True)
    parser.add_argument("--loader", type=Path, required=True)
    parser.add_argument("--helper", type=Path, required=True)
    parser.add_argument("--log-directory", type=Path, required=True)
    parser.add_argument("--expected-launcher-sha256", required=True)
    parser.add_argument("--allow-join", action="store_true", help="Interactive user-driven Join test, without automatic close")
    parser.add_argument("--cef-candidate-dir", type=Path, help="Optional reviewed exact-version game CEF candidate")
    args = parser.parse_args()
    launcher = args.launcher.resolve(strict=True)
    loader = args.loader.resolve(strict=True)
    helper = args.helper.resolve(strict=True)
    cef_arguments = []
    cef_record = None
    if args.cef_candidate_dir:
        if not args.allow_join:
            parser.error("A game CEF candidate requires --allow-join")
        cef_dir = args.cef_candidate_dir.resolve(strict=True)
        manifests = list((cef_dir / "candidate").glob("target-*.json"))
        if len(manifests) != 1:
            raise ValueError("Expected exactly one reviewed CEF candidate manifest")
        manifest = json.loads(manifests[0].read_text())
        version = manifest["file_version"].removesuffix(".0")
        if not re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+", version):
            raise ValueError("Invalid candidate version")
        if digest(launcher.with_name("KcdMp_client.dll")) != manifest["sha256"]:
            raise ValueError("Installed client differs from CEF candidate")
        cef_helper = (cef_dir / f"KcdMpCefCompat-{version}.dll").resolve(strict=True)
        runtime = Path(__file__).resolve().parents[1] / "cef-compat/client_compat/loader/bin"
        cef_loader = (runtime / "kcdmp_compat_loader.exe").resolve(strict=True)
        cef_watcher = (runtime / "kcdmp_compat_watcher.exe").resolve(strict=True)
        cef_arguments = ["--cef-helper",str(cef_helper),"--cef-loader",str(cef_loader),"--cef-watcher",str(cef_watcher),"--cef-client-sha256",manifest["sha256"]]
        cef_record = {"version":version,"client_sha256":manifest["sha256"],"helper_sha256":digest(cef_helper),"watcher_sha256":digest(cef_watcher)}
    if launcher.name != "KcdMp_launcher.exe":
        raise ValueError("Select the original launcher")
    args.log_directory.mkdir(parents=True, exist_ok=False)
    logs = args.log_directory.resolve()
    record = {"stage": "prepared", "native_exit": None}
    if cef_record: record["cef_candidate"] = cef_record
    exit_code = 1
    try:
        with staged_loader(launcher.parent, loader, args.expected_launcher_sha256) as placement:
            record["placement"] = placement
            record["stage"] = "running-interactive" if args.allow_join else "running-view-only"
            (logs / "probe.json").write_text(json.dumps(record, indent=2) + "\n")
            command = [
                str(helper), "--steam-launcher", str(launcher), "--exe", str(launcher),
                "--allowed-root", str(launcher.parent / "ui"),
                "--log-directory", str(logs),
            ]
            command += ["--allow-join"] if args.allow_join else ["--close-after", "40"]
            command += cef_arguments
            process = subprocess.Popen(command)
            try:
                exit_code = process.wait(timeout=None if args.allow_join else 60)
            except subprocess.TimeoutExpired:
                process.terminate()
                try:
                    process.wait(timeout=12)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait()
                exit_code = 124
            record["native_exit"] = exit_code
    finally:
        record["stage"] = "finished"
        (logs / "probe.json").write_text(json.dumps(record, indent=2) + "\n")
    placement = record.get("placement", {})
    if not placement.get("loader_removed") or not all(placement.get("unchanged_originals", {}).values()):
        raise ValueError("Cleanup or original-file verification failed. Inspect probe.json.")
    print("Original launcher probe exited:", exit_code)
    print("Temporary loader removed. Original EXE, client DLL and HTML unchanged.")
    return exit_code


if __name__ == "__main__":
    raise SystemExit(main())

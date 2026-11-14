#!/usr/bin/env python3
"""Bounded native-only probe. It never launches Wine, Steam or the game."""
import argparse
import json
import os
from pathlib import Path
import plistlib
import subprocess


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--helper', type=Path, required=True)
    parser.add_argument('--workdir', type=Path, required=True)
    parser.add_argument('--architecture', choices=('arm64', 'x86_64'))
    parser.add_argument('--reexec', action='store_true')
    args = parser.parse_args()
    helper = args.helper.resolve(strict=True)
    work = args.workdir.resolve()
    work.mkdir(exist_ok=False, parents=True)
    (work / '.metadata_never_index').touch()
    app = work / 'Dock policy check.app'
    (app / 'Contents/MacOS').mkdir(parents=True)
    executable = app / 'Contents/MacOS/DockPolicyFixture'
    (app / 'Contents/Info.plist').write_bytes(plistlib.dumps(dict(
        CFBundleIdentifier='com.kcdmp.dockpolicy.fixture', CFBundleName='Dock policy check',
        CFBundleExecutable='DockPolicyFixture', CFBundlePackageType='APPL')))
    source = Path(__file__).with_name('dock_policy_fixture.swift')
    compiler = ['xcrun', 'swiftc', '-parse-as-library', str(source), '-framework', 'AppKit',
                '-module-cache-path', str(work / 'swift-cache'), '-o', str(executable)]
    if args.architecture:
        compiler += ['-target', args.architecture + '-apple-macosx14.0']
    subprocess.run(compiler, check=True)
    expected = str(work / 'KcdMp_launcher.exe')
    environment = dict(os.environ, DYLD_INSERT_LIBRARIES=str(helper), KCDMP_WEBKIT_BRIDGE_ENABLED='1',
                       KCDMP_WEBKIT_BRIDGE_TOKEN='a'*64, KCDMP_DOCK_EXPECTED_EXE=expected,
                       KCDMP_DOCK_OWNER_PID=str(os.getpid()))
    results = {}
    for name, command, policy in (
        ('launcher', [expected], 1),
        ('game_with_launcher_argument', [str(work / 'KingdomCome.exe'), expected], 0),
        ('launcher_without_owner', [expected], 0),
    ):
        report = work / f'{name}.json'
        current = dict(environment, KCDMP_DOCK_LOG=str(work / f'{name}.log'))
        if name == 'launcher_without_owner':
            current['KCDMP_DOCK_OWNER_PID'] = '2147483647'
        extra = ['--reexec'] if args.reexec else []
        process = subprocess.Popen([str(executable), *command, *extra, str(report)], env=current)
        try:
            status = process.wait(timeout=10)
        except subprocess.TimeoutExpired:
            process.terminate()
            try:
                process.wait(timeout=3)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait()
            raise RuntimeError('Native Dock probe timed out')
        if status != 0:
            raise RuntimeError(f'Native Dock probe exited {status}')
        result = json.loads(report.read_text())
        if result != dict(first=policy, after_repromotion=policy, app_was_precreated=False, preload_leaked=False):
            raise RuntimeError(f'Unexpected native policy result: {name}: {result}')
        results[name] = result
    (work / 'verification.json').write_text(json.dumps(results, indent=2) + '\n')
    print('Native Dock probe passed: launcher accessory, game regular, re-promotion handled, no child preload leak, orphan visible')


if __name__ == '__main__':
    main()

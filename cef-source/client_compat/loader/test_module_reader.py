#!/usr/bin/env python3
"""Run the non-injecting module-reader test in a new disposable Wine prefix."""
import argparse
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[2]


def run(wine, compiler, evidence):
    for executable in (compiler, wine/'wine', wine/'wineboot', wine/'wineserver'):
        if not executable.is_file() or not os.access(executable, os.X_OK):
            raise ValueError('Required executable is unavailable: '+str(executable))
    stage = Path(tempfile.mkdtemp(prefix='kcdmp-module-reader-', dir='/private/tmp'))
    env = dict(os.environ, WINEPREFIX=str(stage/'prefix'), WINEDEBUG='-all')
    results = []
    try:
        for name, command, timeout in [
            ('compile', [str(compiler), '-std=c11', '-O2', '-Wall', '-Wextra', '-Werror', '-municode', str(HERE/'test_modules.c'), '-o', str(stage/'test.exe')], 30),
            ('bootstrap', [str(wine/'wineboot'), '--init'], 40),
            ('module_reader', [str(wine/'wine'), str(stage/'test.exe')], 20),
        ]:
            p = subprocess.run(command, env=env, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=timeout)
            result = dict(name=name, exit=p.returncode, output=p.stdout)
            results.append(result)
            print(name, p.returncode, p.stdout[-1800:], flush=True)
            if p.returncode:
                raise RuntimeError(name+' failed')
            if name == 'module_reader' and 'PASS real watcher module reader:' not in p.stdout:
                raise RuntimeError('Missing explicit test completion')
        return results
    finally:
        try:
            subprocess.run([str(wine/'wineserver'), '-k'], env=env, timeout=10, check=False)
        finally:
            evidence.parent.mkdir(parents=True, exist_ok=True)
            evidence.write_text(json.dumps(results, indent=2)+'\n')
            shutil.rmtree(stage)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--wine-bin', type=Path, required=True,
                        help='Runtime directory containing wine, wineboot and wineserver')
    parser.add_argument('--compiler', type=Path, required=True,
                        help='AMD64 MinGW C compiler')
    parser.add_argument('--report', type=Path,
                        default=ROOT/'.build/module-reader-tests.json')
    args = parser.parse_args()
    run(args.wine_bin.resolve(), args.compiler.resolve(), args.report.resolve())

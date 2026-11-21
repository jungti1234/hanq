#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/test-workspace.sh
stage=$(hanq_test_stage recovery-tests)
trap 'rm -rf "$stage"' EXIT
swiftc -D HANQ_DIAGNOSTIC_TESTING -module-cache-path .build/hanq/module-cache Sources/HanQ/DiagnosticArchiveFormat.swift Sources/HanQ/InputDiagnostics.swift Sources/HanQ/DiagnosticSharedStorage.swift Sources/HanQ/PermissionRecovery.swift Tests/Recovery/main.swift -o "$stage/recovery-tests"
python3 - "$stage/recovery-tests" <<'PY'
import json, os, pathlib, subprocess, sys, tempfile, time
with tempfile.TemporaryDirectory(prefix='hanq-recovery-test-', dir='/private/tmp') as directory:
    marker = pathlib.Path(directory) / 'arguments'
    env = dict(os.environ, HANQ_TEST_RELAUNCH_LOG=str(marker))
    subprocess.run([sys.argv[1], 'arguments-check'], env=env, cwd=directory, timeout=5, check=True)
    for mode in ('requested', 'normal-exit', 'loop-blocked', 'reauthorized', 'duplicate'):
        marker = pathlib.Path(directory) / mode
        env = dict(os.environ, HANQ_TEST_RELAUNCH_LOG=str(marker))
        args = ['--preserve-input-incidents', str(pathlib.Path(directory)/'log path'), '--diagnostic-readiness-token', 'fixture-nonce']
        subprocess.run([sys.argv[1]] + args + [mode], env=env, cwd=directory, timeout=5, check=True)
        expected = mode in ('requested', 'reauthorized')
        end = time.monotonic() + (3 if expected else 0.5)
        while time.monotonic() < end and not marker.exists():
            time.sleep(0.02)
        assert marker.exists() == expected, mode
        if expected:
            assert marker.read_text() == 'relaunched\n', mode
            proof = json.loads(marker.with_suffix('.json').read_text())
            assert proof['arguments'] == args and proof['owner'] > 1, proof
        subprocess.run([sys.argv[1], 'lock-check'], env=env, cwd=directory, timeout=3, check=True)
        print('PASS: permission recovery', mode)
PY

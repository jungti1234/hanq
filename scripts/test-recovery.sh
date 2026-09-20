#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
stage=$(mktemp -d "$PWD/.build/hanq/recovery-tests.XXXXXX")
trap 'rm -rf "$stage"' EXIT
swiftc -module-cache-path .build/hanq/module-cache Sources/HanQ/InputDiagnostics.swift Sources/HanQ/PermissionRecovery.swift Tests/Recovery/main.swift -o "$stage/recovery-tests"
python3 - "$stage/recovery-tests" <<'PY'
import os, pathlib, subprocess, sys, tempfile, time
with tempfile.TemporaryDirectory(prefix='hanq-recovery-test-') as directory:
    for mode in ('requested', 'normal-exit', 'loop-blocked', 'reauthorized', 'duplicate'):
        marker = pathlib.Path(directory) / mode
        env = dict(os.environ, HANQ_TEST_RELAUNCH_LOG=str(marker))
        subprocess.run([sys.argv[1], mode], env=env, timeout=5, check=True)
        expected = mode in ('requested', 'reauthorized')
        end = time.monotonic() + (3 if expected else 0.5)
        while time.monotonic() < end and not marker.exists():
            time.sleep(0.02)
        assert marker.exists() == expected, mode
        if expected:
            assert marker.read_text() == 'relaunched\n', mode
        subprocess.run([sys.argv[1], 'lock-check'], env=env, timeout=3, check=True)
        print('PASS: permission recovery', mode)
PY

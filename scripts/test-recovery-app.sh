#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/test-workspace.sh
stage=$(hanq_test_stage recovery-app)
trap 'rm -rf "$stage"' EXIT
app="$stage/HanQRecoveryTest.app"
mkdir -p "$app/Contents/MacOS"
swiftc -D HANQ_DIAGNOSTIC_TESTING -module-cache-path .build/hanq/module-cache Sources/HanQ/DiagnosticArchiveFormat.swift Sources/HanQ/InputDiagnostics.swift Sources/HanQ/DiagnosticSharedStorage.swift Sources/HanQ/PermissionRecovery.swift Tests/RecoveryApp/main.swift -o "$app/Contents/MacOS/HanQRecoveryTest"
cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>taek.in.hanq.recovery-test</string>
<key>CFBundleExecutable</key><string>HanQRecoveryTest</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>LSUIElement</key><true/>
</dict></plist>
PLIST
codesign --force --sign - "$app"
python3 - "$app" "$stage/trace.log" <<'PY'
import json, pathlib, shutil, subprocess, sys, time, uuid
source, root = pathlib.Path(sys.argv[1]).resolve(), pathlib.Path(sys.argv[2]).resolve().parent
for mode in ('preserve', 'diagnose', 'bounded'):
    run = root / mode
    run.mkdir(mode=0o700)
    app = run / source.name
    shutil.copytree(source, app)
    trace, logs, token = run/'trace.log', run/'log path', str(uuid.uuid4())
    flag = {'preserve':'--preserve-input-incidents', 'diagnose':'--diagnose-input-incidents',
            'bounded':'--bounded-input-incidents'}[mode]
    args = ['--diagnose-input', str(trace), flag, str(logs), '--diagnostic-readiness-token', token]
    subprocess.run(['open', '-n', str(app), '--args'] + args, check=True)
    end = time.monotonic() + 12
    while time.monotonic() < end:
        text = trace.read_text() if trace.exists() else ''
        if 'fixture.recovered' in text:
            assert text.index('recovery.owner.exited') < text.index('fixture.recovered')
            assert text.count('fixture.recovered') == 1
            result = json.loads((run/'recovered.json').read_text())
            owner = int((run/'owner.pid').read_text())
            assert result['owner'] == owner and result['pid'] != owner
            assert result['arguments'] == ['--permission-recovery', '--permission-recovery-from', str(owner)] + args
            assert pathlib.Path(result['directory']).resolve() == logs.resolve() and result['ready'] is True
            proofs = [json.loads((logs/f'.preflight-{token}-{pid}.json').read_text()) for pid in (owner,result['pid'])]
            assert proofs[0]['pid'] == owner and proofs[1]['pid'] == result['pid']
            assert proofs[1]['recoveryFromPID'] == owner and proofs[0]['runID'] != proofs[1]['runID']
            assert all(p['token'] == token and p['ready'] is True and p['bounded'] == (mode=='bounded') for p in proofs)
            print(f'PASS: real LaunchServices {mode} recovery, args and two independent storage proofs')
            break
        time.sleep(.05)
    else:
        print(text)
        raise AssertionError(f'LaunchServices did not complete {mode} recovery')
PY

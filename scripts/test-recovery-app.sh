#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
stage=$(mktemp -d "$PWD/.build/hanq/recovery-app.XXXXXX")
trap 'rm -rf "$stage"' EXIT
app="$stage/HanQRecoveryTest.app"
mkdir -p "$app/Contents/MacOS"
swiftc -module-cache-path .build/hanq/module-cache Sources/HanQ/InputDiagnostics.swift Sources/HanQ/PermissionRecovery.swift Tests/RecoveryApp/main.swift -o "$app/Contents/MacOS/HanQRecoveryTest"
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
import pathlib, subprocess, sys, time
app, trace = pathlib.Path(sys.argv[1]).resolve(), pathlib.Path(sys.argv[2]).resolve()
subprocess.run(['open', '-n', str(app), '--args', '--diagnose-input', str(trace)], check=True)
end = time.monotonic() + 10
while time.monotonic() < end:
    text = trace.read_text() if trace.exists() else ''
    if 'fixture.recovered' in text:
        assert text.index('recovery.owner.exited') < text.index('fixture.recovered')
        assert text.count('fixture.recovered') == 1
        print(text)
        print('PASS: real LaunchServices recovery after owner exit')
        break
    time.sleep(.05)
else:
    print(text)
    raise AssertionError('LaunchServices did not start the recovery instance')
PY

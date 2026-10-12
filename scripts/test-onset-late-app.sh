#!/bin/bash
# Requires the exact running HanQ candidate's completed permission preflight.
# Uses global HID + real AX only in an owned fixture; restores input sources.
set -euo pipefail
cd "$(dirname "$0")/.."
record=${1:?사용법: test-onset-late-app.sh record.json 새-결과-디렉터리}
output=${2:?새 결과 디렉터리가 필요합니다}
mode=${3:-}
prior=${4:-}
python3 scripts/prepare-app-test.py check "$record"
if [[ -e "$output" ]]; then echo '결과 디렉터리를 덮어쓰지 않습니다.' >&2; exit 1; fi
mkdir -p "$output"
output=$(cd "$output" && pwd)
source scripts/test-workspace.sh
ipc=$(hanq_test_stage late-app)
printf '%s\n' "$ipc" > "$output/ipc-path.txt"
if [[ -n "$prior" ]]; then cp "$prior" "$ipc/prior.json"; fi
app="$ipc/LateAppFixture.app"
mkdir -p "$app/Contents/MacOS"
cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?><!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd"><plist version="1.0"><dict><key>CFBundleExecutable</key><string>LateAppFixture</string><key>CFBundleIdentifier</key><string>taek.in.hanq.late-layout-fixture</string><key>CFBundleName</key><string>LateAppFixture</string><key>NSPrincipalClass</key><string>NSApplication</string></dict></plist>
PLIST
swiftc -module-cache-path .build/hanq/module-cache Sources/HanQ/JamoComposer.swift Sources/HanQ/KoreanKeyboardLayout.swift Sources/HanQ/InputSourceAccess.swift Tests/OnsetRecovery/LateLayoutCases.swift Tests/OnsetRecovery/LateApp/main.swift -o "$app/Contents/MacOS/LateAppFixture"
swiftc -module-cache-path .build/hanq/module-cache Sources/HanQ/KeyboardStateMirror.swift Tests/OnsetRecovery/LateApp/PostedKeys.swift Tests/OnsetRecovery/LateApp/sender.swift -o "$ipc/sender"
codesign --force --sign - "$app"
if [[ "$mode" == --physical || "$mode" == --physical-normal ]]; then
    open -n "$app" --args "$ipc/results.json" "$mode"
else
    (cd "$ipc"; exec ./sender "$ipc") > "$output/sender.log" 2>&1 &
    sender_pid=$!
    trap 'kill "$sender_pid" 2>/dev/null || true; wait "$sender_pid" 2>/dev/null || true' EXIT
    open -n "$app" --args "$ipc/results.json"
fi
run_status=0
python3 - "$ipc/results.json" "$mode" <<'PY' || run_status=$?
import json,pathlib,sys,time
p=pathlib.Path(sys.argv[1]);deadline=time.monotonic()+(1200 if sys.argv[2] in ("--physical","--physical-normal") else 70)
while time.monotonic()<deadline:
    if p.exists():
        r=json.loads(p.read_text());print(('PASS' if r['passed'] else 'FAIL')+': '+r['reason']);print('기록: '+str(p));sys.exit(0 if r['passed'] else 1)
    time.sleep(.1)
raise SystemExit('FAIL: fixture timeout; no pass recorded')
PY
for name in results.json progress.json ready.json; do
    if [[ -f "$ipc/$name" ]]; then cp "$ipc/$name" "$output/$name"; fi
done
exit "$run_status"

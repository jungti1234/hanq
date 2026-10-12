#!/bin/bash
# Human input only in an owned window; no key posts or global event taps.
set -euo pipefail
cd "$(dirname "$0")/.."
record=${1:?사용법: test-keyboard-state-physical.sh record.json 새-결과-디렉터리}
output=${2:?새 결과 디렉터리가 필요합니다}
prior=${3:-}
mode=""
if [[ "$prior" == --verify-editor ]]; then mode="$prior"; prior=""; fi
python3 scripts/prepare-app-test.py check "$record"
[[ ! -e "$output" ]] || { echo '기존 결과를 덮어쓰지 않습니다.' >&2; exit 1; }
mkdir -p "$output"
output=$(cd "$output" && pwd)
source scripts/test-workspace.sh
stage=$(hanq_test_stage physical-keys)
printf '%s\n' "$stage" > "$output/ipc-path.txt"
[[ -z "$prior" ]] || cp "$prior" "$stage/prior.json"
app="$stage/HanQPhysicalKeys.app"
mkdir -p "$app/Contents/MacOS"
swiftc -module-cache-path .build/hanq/module-cache Sources/HanQ/InputSourceAccess.swift Tests/KeyboardStateMirror/Physical/main.swift -o "$app/Contents/MacOS/HanQPhysicalKeys"
python3 - "$app" <<'PY'
import pathlib,plistlib,sys
p=pathlib.Path(sys.argv[1])/'Contents/Info.plist'
p.write_bytes(plistlib.dumps(dict(CFBundleIdentifier='taek.in.hanq.physical-key-tests',CFBundleExecutable='HanQPhysicalKeys',CFBundleName='HanQ Physical Keys',CFBundlePackageType='APPL',NSPrincipalClass='NSApplication')))
PY
codesign --force --sign - "$app"
if [[ -n "$mode" ]]; then open -n "$app" --args "$stage" "$mode"; else open -n "$app" --args "$stage"; fi
status=0
python3 - "$stage/results.json" <<'PY' || status=$?
import json,pathlib,sys,time
p=pathlib.Path(sys.argv[1]);deadline=time.monotonic()+1210
while time.monotonic()<deadline:
    if p.exists():
        r=json.loads(p.read_text());print(('PASS: ' if r['passed'] else 'FAIL: ')+r['reason']);sys.exit(0 if r['passed'] else 1)
    time.sleep(.1)
raise SystemExit('FAIL: no physical result recorded')
PY
for name in results.json ready.json progress.json; do
    [[ ! -f "$stage/$name" ]] || cp "$stage/$name" "$output/$name"
done
exit "$status"

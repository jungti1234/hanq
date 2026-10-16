#!/bin/bash
# Running HanQ, guarded HID and real IMEs in an owned editor. No physical keys.
set -euo pipefail
cd "$(dirname "$0")/.."
record=${1:?사용법: test-onset-active-app.sh record.json 새-결과-디렉터리}
output=${2:?새 결과 디렉터리가 필요합니다}
python3 scripts/prepare-app-test.py check "$record"
if [[ -e "$output" ]]; then echo '결과 디렉터리를 덮어쓰지 않습니다.' >&2; exit 1; fi
mkdir -p "$output"
output=$(cd "$output" && pwd)
source scripts/test-workspace.sh
stage=$(hanq_test_stage onset-active-app)
printf '%s\n' "$stage" > "$output/stage.txt"
app="$stage/ActiveFixture.app"
mkdir -p "$app/Contents/MacOS"
cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?><!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd"><plist version="1.0"><dict><key>CFBundleExecutable</key><string>ActiveFixture</string><key>CFBundleIdentifier</key><string>taek.in.hanq.late-layout-fixture</string><key>CFBundleName</key><string>HanQ active composition test</string><key>NSPrincipalClass</key><string>NSApplication</string></dict></plist>
PLIST
swiftc -module-cache-path .build/hanq/module-cache Sources/HanQ/JamoComposer.swift Sources/HanQ/KoreanKeyboardLayout.swift Sources/HanQ/InputSourceAccess.swift Tests/OnsetRecovery/LateLayoutCases.swift Tests/OnsetRecovery/ActiveApp/main.swift -o "$app/Contents/MacOS/ActiveFixture"
swiftc -module-cache-path .build/hanq/module-cache Sources/HanQ/KeyboardStateMirror.swift Tests/OnsetRecovery/LateApp/PostedKeys.swift Tests/OnsetRecovery/LateApp/sender.swift -o "$stage/sender"
codesign --force --sign - "$app"
(cd "$stage"; exec ./sender "$stage") > "$output/sender.log" 2>&1 &
sender=$!
trap 'kill "$sender" 2>/dev/null || true; wait "$sender" 2>/dev/null || true' EXIT
open -n "$app" --args "$stage"
status=0
python3 - "$stage" <<'PY' || status=$?
import json,pathlib,sys,time
p=pathlib.Path(sys.argv[1]);end=time.monotonic()+220
while time.monotonic()<end:
 if (p/'results.json').exists():
  r=json.loads((p/'results.json').read_text());print(json.dumps({'passed':r['passed'],'reason':r['reason'],'cases':len(r['cases']),'restored':r['restored']},ensure_ascii=False));sys.exit(0 if r['passed'] else 1)
 time.sleep(.1)
raise SystemExit('fixture timeout; no pass recorded')
PY
for name in results.json progress.json ready.json; do
 if [[ -f "$stage/$name" ]]; then cp "$stage/$name" "$output/$name"; fi
done
exit "$status"

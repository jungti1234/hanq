#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
record=${1:?record.json};output=${2:?new-output-dir};mode=${3:---expect-normal}
[[ "$mode" == --expect-normal || "$mode" == --expect-split ]]
python3 scripts/prepare-app-test.py check "$record"
[[ ! -e "$output" ]];mkdir -p "$output";output=$(cd "$output" && pwd)
source scripts/test-workspace.sh
stage=$(hanq_test_stage onset-prefocus);printf '%s\n' "$stage" > "$output/stage.txt"
app="$stage/PrefocusFixture.app";mkdir -p "$app/Contents/MacOS"
cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?><!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd"><plist version="1.0"><dict><key>CFBundleExecutable</key><string>PrefocusFixture</string><key>CFBundleIdentifier</key><string>taek.in.hanq.prefocus-fixture</string><key>CFBundleName</key><string>HanQ first-focus verification</string><key>NSPrincipalClass</key><string>HanQPrefocusApplication</string></dict></plist>
PLIST
swiftc -module-cache-path .build/hanq/module-cache Sources/HanQ/JamoComposer.swift Sources/HanQ/KoreanKeyboardLayout.swift Sources/HanQ/InputSourceAccess.swift Tests/OnsetRecovery/LateLayoutCases.swift Tests/OnsetRecovery/PrefocusApp/main.swift -o "$app/Contents/MacOS/PrefocusFixture"
swiftc -module-cache-path .build/hanq/module-cache Sources/HanQ/KeyboardStateMirror.swift Tests/OnsetRecovery/LateApp/PostedKeys.swift Tests/OnsetRecovery/LateApp/sender.swift -o "$stage/sender"
codesign --force --sign - "$app"
(cd "$stage";exec ./sender "$stage" --prefocus-fixture) > "$output/sender.log" 2>&1 &
sender=$!;trap 'kill "$sender" 2>/dev/null || true; wait "$sender" 2>/dev/null || true' EXIT
if [[ -n "${HANQ_PREFOCUS_CASE_LIMIT:-}" ]];then
 python3 - "$stage" "$HANQ_PREFOCUS_CASE_LIMIT" <<'LIMIT'
import json,pathlib,sys
n=int(sys.argv[2]);assert 1<=n<=27
(pathlib.Path(sys.argv[1])/'case-limit.json').write_text(json.dumps({'limit':n}))
LIMIT
fi
if [[ -n "${HANQ_PREFOCUS_MODEL:-}" ]];then
 python3 - "$stage" "$HANQ_PREFOCUS_MODEL" <<'MODEL'
import json,pathlib,sys
model=sys.argv[2];assert model in ['unpublished','display-empty','display-draft','placeholder-as-content','literal-hint-draft','first-consonant','first-consonant-empty','first-consonant-stale-lf','first-consonant-stale-hint','first-word','native-marked-stale-focus','fast-pointer-reentry','draft-reentry','late-pair-empty','late-pair-draft','late-normal-empty','late-normal-draft']
(pathlib.Path(sys.argv[1])/'model.json').write_text(json.dumps({'model':model}))
MODEL
fi
open -n "$app" --args "$stage" "$mode"
status=0
python3 - "$stage" <<'PY' || status=$?
import pathlib,json,sys,time
p=pathlib.Path(sys.argv[1]);end=time.monotonic()+100
while time.monotonic()<end:
 if (p/'results.json').exists():
  r=json.loads((p/'results.json').read_text());print(json.dumps({'passed':r['passed'],'reason':r['reason'],'cases':len(r['cases']),'restored':r['restored']}));sys.exit(0 if r['passed'] else 1)
 time.sleep(.1)
(p/'abort.json').write_text('{}')
raise SystemExit('fixture timeout, abort requested; no pass recorded')
PY
for name in results.json progress.json ready.json;do if [[ -f "$stage/$name" ]];then cp "$stage/$name" "$output/$name";fi;done
exit "$status"

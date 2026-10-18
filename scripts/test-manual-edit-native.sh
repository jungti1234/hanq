#!/bin/bash
# Exact installed HanQ, global HID only to an owned synthetic editor.
set -euo pipefail
cd "$(dirname "$0")/.."
record=${1:?usage: test-source-timestamps-native.sh record.json new-output-directory}
output=${2:?new output directory required}
python3 scripts/prepare-app-test.py check "$record"
[[ ! -e "$output" ]]
mkdir -p "$output"
output=$(cd "$output" && pwd)
ipc=$(mktemp -d /private/tmp/hanq-source-time.XXXXXX)
printf '%s\n' "$ipc" > "$output/ipc-path.txt"
app="$ipc/HanjaCommandFixture.app"
mkdir -p "$app/Contents/MacOS"
cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?><!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd"><plist version="1.0"><dict><key>CFBundleExecutable</key><string>Fixture</string><key>CFBundleIdentifier</key><string>taek.in.hanq.hanja-command-fixture</string><key>CFBundleName</key><string>HanjaCommandFixture</string><key>NSPrincipalClass</key><string>NSApplication</string></dict></plist>
PLIST
swiftc -module-cache-path .build/hanq/module-cache Tests/ManualEdit/Native/fixture.swift -o "$app/Contents/MacOS/Fixture"
swiftc -module-cache-path .build/hanq/module-cache Sources/HanQ/KeyboardStateMirror.swift Tests/OnsetRecovery/LateApp/PostedKeys.swift Tests/ManualEdit/Native/sender.swift -o "$ipc/sender"
swiftc -module-cache-path .build/hanq/module-cache Tests/SourceTimestamps/Native/marker.swift -o "$ipc/marker"
codesign --force --sign - "$app"
(cd "$ipc"; exec ./sender "$ipc") > "$output/sender.log" 2>&1 &
sender_pid=$!
trap 'touch "$ipc/quit"; wait "$sender_pid" 2>/dev/null || true' EXIT
open -n "$app" --args "$ipc"
status=0
python3 - "$ipc" <<'PY' || status=$?
import json,pathlib,sys,time
root=pathlib.Path(sys.argv[1]);end=time.monotonic()+35
while time.monotonic()<end:
 p=root/'result.json'
 if p.exists():
  d=json.loads(p.read_text());print(json.dumps(d,ensure_ascii=False,indent=2));sys.exit(0 if d['passed'] else 1)
 time.sleep(.1)
raise SystemExit('FAIL: owned fixture timeout; no pass recorded')
PY
for name in ready.json result.json; do
 [[ ! -f "$ipc/$name" ]] || cp "$ipc/$name" "$output/$name"
done
# Mark while the successful/failed synthetic input is still in the recent ring.
# Missing diagnostic UI is explicit and does not claim capture success.
python3 - "$record" "$ipc/marker" "$output/marker.log" <<'PYMARK'
import json,pathlib,subprocess,sys
r=json.loads(pathlib.Path(sys.argv[1]).read_text())
p=subprocess.run([sys.argv[2],str(r['main_pid']),r['app']['path']],capture_output=True,text=True)
pathlib.Path(sys.argv[3]).write_text(p.stdout+p.stderr+'exit='+str(p.returncode)+'\n')
print(p.stdout.strip())
PYMARK
exit "$status"

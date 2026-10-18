#!/bin/bash
# Explicit installed-app check, owned editor only, no global keys.
set -euo pipefail
cd "$(dirname "$0")/.."
record=${1:?permission record required}
output=${2:?new output directory required}
python3 scripts/prepare-app-test.py check "$record"
[[ ! -e "$output" ]]
mkdir -p "$output"
output=$(cd "$output" && pwd)
stage=$(mktemp -d /private/tmp/hanq-ax-semantics.XXXXXX)
app="$stage/AXSemanticsFixture.app"
mkdir -p "$app/Contents/MacOS"
cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?><!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd"><plist version="1.0"><dict><key>CFBundleExecutable</key><string>Fixture</string><key>CFBundleIdentifier</key><string>taek.in.hanq.ax-semantics-fixture</string><key>CFBundleName</key><string>AXSemanticsFixture</string><key>NSPrincipalClass</key><string>NSApplication</string></dict></plist>
PLIST
swiftc -module-cache-path .build/hanq/module-cache Tests/Diagnostics/AXSemantics/fixture.swift -o "$app/Contents/MacOS/Fixture"
swiftc -module-cache-path .build/hanq/module-cache Tests/SourceTimestamps/Native/marker.swift -o "$stage/marker"
codesign --force --sign - "$app"
open -n "$app" --args "$output/result.json"
python3 - "$output/result.json" <<'PY'
import pathlib,json,sys,time
path=pathlib.Path(sys.argv[1]);end=time.monotonic()+12
while time.monotonic()<end:
 if path.exists():
  value=json.loads(path.read_text());print(json.dumps(value));sys.exit(0 if value['passed'] else 1)
 time.sleep(.1)
raise SystemExit('FAIL owned metadata fixture timeout')
PY
python3 - "$record" "$stage/marker" "$output/marker.log" <<'PY'
import json,pathlib,subprocess,sys
record=json.loads(pathlib.Path(sys.argv[1]).read_text());run=subprocess.run([sys.argv[2],str(record['main_pid']),record['app']['path']],capture_output=True,text=True)
pathlib.Path(sys.argv[3]).write_text(run.stdout+run.stderr+'exit='+str(run.returncode)+'\n');print(run.stdout.strip());sys.exit(run.returncode)
PY

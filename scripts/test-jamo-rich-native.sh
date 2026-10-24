#!/bin/bash
# Installed HanQ + owned rich NSTextView; synthetic keys, never physical proof.
set -euo pipefail
cd "$(dirname "$0")/.."
record=${1:?usage: test-jamo-rich-native.sh approved-record.json new-output-directory}
output=${2:?new output directory required}
python3 scripts/prepare-app-test.py check "$record"
[[ ! -e "$output" ]]
mkdir -p "$output"
output=$(cd "$output" && pwd)
ipc=$(mktemp -d /private/tmp/hanq-jamo-rich.XXXXXX)
printf '%s\n' "$ipc" > "$output/ipc-path.txt"
app="$ipc/RichFixture.app"
mkdir -p "$app/Contents/MacOS" "$ipc/module-cache"
cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?><!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd"><plist version="1.0"><dict><key>CFBundleExecutable</key><string>Fixture</string><key>CFBundleIdentifier</key><string>taek.in.hanq.jamo-rich-fixture</string><key>CFBundleName</key><string>HanQ Rich Text Test</string><key>NSPrincipalClass</key><string>NSApplication</string></dict></plist>
PLIST
swiftc -module-cache-path "$ipc/module-cache" Sources/HanQ/JamoComposer.swift Sources/HanQ/JamoPasteboard.swift Sources/HanQ/KoreanKeyboardLayout.swift Tests/JamoEdits/RichFixture.swift -o "$app/Contents/MacOS/Fixture"
swiftc -module-cache-path "$ipc/module-cache" Tests/Support/OwnedInputFocus.swift Sources/HanQ/KeyboardStateMirror.swift Tests/OnsetRecovery/LateApp/PostedKeys.swift Tests/JamoEdits/Sender.swift -o "$ipc/sender"
codesign --force --sign - "$app"
active_ipc="$ipc"
sender_pid=
trap 'touch "$active_ipc/quit"; if [[ -n "$sender_pid" ]]; then wait "$sender_pid" 2>/dev/null || true; fi' EXIT
run_fixture() {
  local trial=$1 destination=$2 status=0
  active_ipc=$trial
  mkdir -p "$destination"
  printf '%s\n' "$trial" > "$destination/ipc-path.txt"
  "$trial/sender" "$trial" > "$destination/sender.log" 2>&1 &
  sender_pid=$!
  open -n "$trial/RichFixture.app" --args "$trial"
  python3 - "$trial" "$destination" <<'PY' || status=$?
from pathlib import Path
import json, shutil, sys, time
root, out = map(Path, sys.argv[1:])
end = time.monotonic() + 100
while time.monotonic() < end and not (root/'result.json').exists():
    time.sleep(.1)
if not (root/'result.json').exists():
    raise SystemExit('FAIL: owned rich-text fixture produced no result')
data = json.loads((root/'result.json').read_text())
for source in root.iterdir():
    if source.name in ('RichFixture.app', 'sender', 'module-cache'):
        continue
    target = out/source.name
    if source.is_dir(): shutil.copytree(source, target)
    else: shutil.copy2(source, target)
control = data.get('nativeControl', False)
passed = data['completed'] and data['originalClipboardRestored'] and len(data['cases']) == (6 if control else 9)
for row in data['cases']:
    if row['name'] in ('rejected-multi','context-change'):
        passed &= row.get('safeNoPaste', False)
        continue
    for key in ('attachments','attachmentSHA256','linkValues','linkedUTF16','boldUTF16'):
        for stage in ('after','undo','redo'):
            passed &= row[stage][key] == row['before'][key]
    passed &= row.get('oneUndoRestoredText', False) and row.get('redoRestoredText', False)
    passed &= row.get('unchangedFormattingPreserved', False) and row.get('oneUndoRestoredFormatting', False) and row.get('redoUnchangedFormattingPreserved', False)
    passed &= row.get('finalCaretPreserved', False)
    if not control: passed &= row.get('redoCaretMatchesNative', False)
    passed &= row.get('externalClipboardPreserved', False) if row['name']=='late-clipboard' else row.get('clipboardMarkerRestored', False)
summary = {'passed': bool(passed), 'cases': len(data['cases']), 'physicalKeys': False,
           'actualInstalledApp': not control, 'nativeControl': control, 'source': str(out/'result.json')}
(out/'summary.json').write_text(json.dumps(summary, indent=2)+'\n')
print(json.dumps(summary, indent=2))
raise SystemExit(0 if passed else 1)
PY
  touch "$trial/quit"
  wait "$sender_pid" || status=$?
  sender_pid=
  return "$status"
}
# Compare with the same real Command-V/Undo/Redo path, without a HanQ edit.
# Programmatic undoManager.redo() can report a different native caret.
control_ipc=$(mktemp -d /private/tmp/hanq-jamo-rich-control.XXXXXX)
cp -Rp "$app" "$control_ipc/RichFixture.app"
cp "$ipc/sender" "$control_ipc/sender"
touch "$control_ipc/native-control"
run_fixture "$control_ipc" "$output/native-control"
cp "$output/native-control/result.json" "$ipc/native-expected.json"
run_fixture "$ipc" "$output"

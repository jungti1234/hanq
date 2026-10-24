#!/bin/bash
# Explicit native clipboard integration test; not run by the normal build.
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/test-workspace.sh
stage=$(hanq_test_stage retained-copy)
app="$stage/RetainedCopy.app"
mkdir -p "$app/Contents/MacOS"
swiftc -module-cache-path .build/hanq/module-cache Sources/HanQ/KeyboardStateMirror.swift Sources/HanQ/InputFocusAccess.swift Sources/HanQ/InputDeliveryOrigin.swift Sources/HanQ/InputSourceAccess.swift Sources/HanQ/PhysicalLetterKeys.swift Sources/HanQ/Mismatch*.swift Sources/HanQ/OnsetInputGate.swift Sources/HanQ/OnsetSafetyDiagnostics.swift Sources/HanQ/SyntheticInputMarker.swift Sources/HanQ/InputDiagnostics.swift Sources/HanQ/CommandFilter.swift Sources/HanQ/JamoComposer.swift Sources/HanQ/KoreanKeyboardLayout.swift Tests/RetainedInputCopy/main.swift -o "$app/Contents/MacOS/RetainedCopy"
cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict><key>CFBundleIdentifier</key><string>taek.in.hanq.retained-copy-tests</string><key>CFBundleExecutable</key><string>RetainedCopy</string><key>CFBundleName</key><string>RetainedCopy</string><key>CFBundlePackageType</key><string>APPL</string><key>LSUIElement</key><true/></dict></plist>
PLIST
open -n "$app" --args "$stage" "$@"
for attempt in {1..100}; do
    if [[ -f "$stage/result.json" ]]; then break; fi
    sleep 0.1
done
python3 - "$stage/result.json" <<'PY'
import json,sys
p=sys.argv[1]
with open(p) as f: result=json.load(f)
print(json.dumps(result,ensure_ascii=False,indent=2))
print('Artifact: '+p)
raise SystemExit(0 if result['passed'] else 1)
PY

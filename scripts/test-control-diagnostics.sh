#!/bin/bash
# Synthetic event objects only; AppKit requires the ordinary local environment.
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/test-workspace.sh
stage=$(hanq_test_stage control-diagnostics)
trap 'rm -rf "$stage"' EXIT
mkdir -p .build/hanq/module-cache
swiftc -D HANQ_DIAGNOSTIC_TESTING -module-cache-path .build/hanq/module-cache Sources/HanQ/KeyboardStateMirror.swift Sources/HanQ/InputFocusAccess.swift Sources/HanQ/InputDeliveryOrigin.swift Sources/HanQ/InputSourceAccess.swift Sources/HanQ/InputSourceObserver.swift Sources/HanQ/PhysicalLetterKeys.swift Sources/HanQ/Mismatch*.swift Sources/HanQ/OnsetInputGate.swift Sources/HanQ/OnsetSafetyDiagnostics.swift Sources/HanQ/SyntheticInputMarker.swift Sources/HanQ/InputDiagnostics.swift Sources/HanQ/CommandFilter.swift Sources/HanQ/JamoComposer.swift Sources/HanQ/KoreanKeyboardLayout.swift Tools/InputTestRecorder/RecorderCore.swift Tests/Diagnostics/Controls/main.swift -o "$stage/tests"
hanq_test_run "$stage/tests" "$stage/control.json"
python3 -B scripts/summarize-input-incident.py "$stage/control.json" > "$stage/summary.json"
python3 - "$stage/summary.json" <<'PY'
import json,sys
v=json.load(open(sys.argv[1]));assert len(v['control_decisions'])>=30
print('PASS control diagnostic summary and typed delivery counters')
PY

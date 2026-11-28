#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/test-workspace.sh
stage=$(hanq_test_stage right-command-layout)
trap 'rm -rf "$stage"' EXIT
[[ $stage == /private/tmp/hanq-right-command-layout.* && ! -L $stage && $(stat -f '%u:%Lp' "$stage") == "$(id -u):700" ]]
mkdir -p .build/hanq/module-cache
swiftc -D HANQ_DIAGNOSTIC_TESTING -module-cache-path .build/hanq/module-cache \
    Sources/HanQ/{DiagnosticArchiveFormat,InputDiagnostics,DiagnosticSharedStorage,DiagnosticReview}.swift \
    Sources/HanQ/{KeyboardStateMirror,InputFocusAccess,InputDeliveryOrigin,InputSourceAccess,PhysicalLetterKeys}.swift \
    Sources/HanQ/Mismatch*.swift Sources/HanQ/{OnsetInputGate,OnsetSafetyDiagnostics,SyntheticInputMarker}.swift \
    Sources/HanQ/{CommandFilter,JamoComposer,KoreanKeyboardLayout,SafariInputActivation}.swift \
    Sources/HanQ/{SourceSwitchBarrier,SelectionPreservingSourceSwitch,RightCommandLayoutDiagnostics}.swift \
    Tools/InputTestRecorder/RecorderCore.swift Tests/SourceSwitchBarrier/ConfirmedReturnTests.swift \
    Tests/SourceSwitchBarrier/LocalTypingWindowTests.swift \
    Tests/Diagnostics/RightCommandLayout/main.swift -o "$stage/layout-tests"
hanq_test_run "$stage/layout-tests"
manual=$(cat "$stage/manual-name")
python3 scripts/summarize-input-incident.py "$stage/store/Shared-v1/$manual" > "$stage/summary.json"
python3 - "$stage/summary.json" <<'PY'
import json
import sys
with open(sys.argv[1]) as stream:
    report = json.load(stream)
(row,) = report["right_command_layouts"]
assert (row["targetName"], row["commit"]["layoutName"], row["firstKey"]["layoutName"],
        row["first_key_after_commit_us"]) == ("two_set", "ABC", "two_set", 707000)
assert report["detection_decision_counts"]["event"]["snapshot_unavailable"] == 9
print("PASS independent Python reader of the compressed manual capture: one transition, 707 ms, nine unreadable keys")
PY
if [[ $# == 1 ]]; then
    mkdir -p "$1/Shared-v1"
    cp "$stage/summary.json" "$stage/manual-name" "$1/"
    cp "$stage/store/Shared-v1"/shared-*.hqdiag "$1/Shared-v1/"
fi

#!/bin/bash
# Product engine tests: injected snapshots/events, no global key posting.
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build/hanq
source scripts/test-workspace.sh
stage=$(hanq_test_stage mismatch)
trap 'rm -rf "$stage"' EXIT
swiftc Sources/HanQ/KeyboardStateMirror.swift -module-cache-path .build/hanq/module-cache Sources/HanQ/InputFocusAccess.swift Sources/HanQ/InputDeliveryOrigin.swift Sources/HanQ/InputSourceAccess.swift Sources/HanQ/PhysicalLetterKeys.swift Sources/HanQ/Mismatch*.swift Sources/HanQ/OnsetInputGate.swift Sources/HanQ/OnsetSafetyDiagnostics.swift Sources/HanQ/InputDiagnostics.swift Sources/HanQ/CommandFilter.swift Sources/HanQ/JamoComposer.swift Sources/HanQ/KoreanKeyboardLayout.swift Tests/MismatchRecovery/*.swift -o "$stage/mismatch-tests"
mkdir -p "$stage/Tests/MismatchRecovery"
cp Tests/MismatchRecovery/NativeLayoutExpectations.json "$stage/Tests/MismatchRecovery/"
for mode in fragmented-proof event-target-following layouts buffered-jamo composition-continuation source-settlement paced-replay monitor-lifecycle activation-shortcut source-timestamps select-all-boundary shortcut-source-state source-interactions delivered-key-release mixed-transition delivery-progress editor-coordinates web-spaces idle-observation async-snapshot fast-overwrite source-interruption snapshot-retry early-retry retry-settle replay-verification release-sources app-following boundary-gate detection-only retry-exhaustion modifier-loop focus-routing field-tracking rollback; do
    hanq_test_run "$stage/mismatch-tests" "--test-$mode"
done
hanq_test_run "$stage/mismatch-tests" --test-product --diagnose-input "$stage/privacy.log"
hanq_test_run "$stage/mismatch-tests" --test-product --diagnose-input-incidents "$stage/incidents"
hanq_test_run "$stage/mismatch-tests" --test-paced-replay --diagnose-input-incidents "$stage/incidents"
if rg -q 'PRIVATE_MISMATCH_PAYLOAD|"text"|"code"' "$stage/privacy.log"; then exit 1; fi
rg -q 'mismatch.mismatch_confirmed' "$stage/privacy.log"

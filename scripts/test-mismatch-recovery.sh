#!/bin/bash
# Product engine tests: injected snapshots/events, no global key posting.
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build/hanq
stage=$(mktemp -d "$PWD/.build/hanq/mismatch.XXXXXX")
trap 'rm -rf "$stage"' EXIT
swiftc -module-cache-path .build/hanq/module-cache Sources/HanQ/InputSourceAccess.swift Sources/HanQ/PhysicalLetterKeys.swift Sources/HanQ/Mismatch*.swift Sources/HanQ/OnsetInputGate.swift Sources/HanQ/InputDiagnostics.swift Sources/HanQ/CommandFilter.swift Sources/HanQ/JamoComposer.swift Sources/HanQ/KoreanKeyboardLayout.swift Tests/MismatchRecovery/*.swift -o "$stage/tests"
for mode in layouts delivery-progress editor-coordinates web-spaces async-snapshot fast-overwrite source-interruption snapshot-retry early-retry replay-verification release-sources app-following boundary-gate detection-only retry-exhaustion modifier-loop focus-routing field-tracking rollback; do
    "$stage/tests" "--test-$mode"
done
"$stage/tests" --test-product --diagnose-input "$stage/privacy.log"
if rg -q 'PRIVATE_MISMATCH_PAYLOAD|"text"|"code"' "$stage/privacy.log"; then exit 1; fi
rg -q 'mismatch.mismatch_confirmed' "$stage/privacy.log"

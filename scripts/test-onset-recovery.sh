#!/bin/bash
# Run outside the restricted AppKit sandbox. No global taps or actual key posts.
set -euo pipefail
cd "$(dirname "$0")/.."
stage=$(mktemp -d "$PWD/.build/hanq/onset.XXXXXX")
trap 'rm -rf "$stage"' EXIT
swiftc -module-cache-path .build/hanq/module-cache Sources/HanQ/Onset*.swift Sources/HanQ/InputDiagnostics.swift Sources/HanQ/KoreanKeyboardLayout.swift Tests/OnsetRecovery/main.swift -o "$stage/tests"
for mode in layouts ack-timeout shift-onset early-capture restart recovery selection-retry selected-replacement superseded selection-read auto-resume prefix-delay drain rollback field-tracking; do
    "$stage/tests" "--test-$mode"
done
"$stage/tests" --test-integration --diagnose-input "$stage/privacy.log"
if rg -q 'PRIVATE_ONSET_PAYLOAD|"code"|"events"' "$stage/privacy.log"; then exit 1; fi
rg -q 'onset.privacy_check' "$stage/privacy.log"
echo 'PASS: production onset diagnostics omit text, clipboard and key payloads'
# Run focused detector, gate and deletion-event checks against product implementations.
for group in detector gate delete; do
    case "$group" in
        detector) fixture=Tests/OnsetRecovery/Detector/main.swift; sources=(Sources/HanQ/OnsetRecoveryPlan.swift Sources/HanQ/OnsetRecoveryDetector.swift Sources/HanQ/OnsetKeyboardLayout.swift Sources/HanQ/KoreanKeyboardLayout.swift) ;;
        gate) fixture=Tests/OnsetRecovery/Gate/main.swift; sources=(Sources/HanQ/OnsetInputGate.swift) ;;
        delete) fixture=Tests/OnsetRecovery/DeleteKey/main.swift; sources=(Sources/HanQ/OnsetDeletionKey.swift) ;;
    esac
    sed -e 's/RecoveryPlan/OnsetRecoveryPlan/g' -e 's/OnsetDetector/OnsetRecoveryDetector/g' -e 's/InputGate/OnsetInputGate/g' -e 's/DeletionKey/OnsetDeletionKey/g' "$fixture" > "$stage/main.swift"
    swiftc -module-cache-path .build/hanq/module-cache "${sources[@]}" "$stage/main.swift" -o "$stage/$group"
    "$stage/$group"
done

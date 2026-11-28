#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/test-workspace.sh
stage=$(hanq_test_stage switch-barrier)
trap 'rm -rf "$stage"' EXIT
native=false
test_sources=(Tests/SourceSwitchBarrier/*.swift)
if [[ ${1:-} == --native-caret ]]; then
  shift
  native=true
  test_sources=(Tests/SourceSwitchBarrier/NativeCaret/main.swift)
fi
swiftc -D HANQ_DIAGNOSTIC_TESTING Sources/HanQ/KeyboardStateMirror.swift -module-cache-path .build/hanq/module-cache Sources/HanQ/InputFocusAccess.swift Sources/HanQ/InputDeliveryOrigin.swift Sources/HanQ/InputSourceAccess.swift Sources/HanQ/PhysicalLetterKeys.swift Sources/HanQ/Mismatch*.swift Sources/HanQ/OnsetInputGate.swift Sources/HanQ/OnsetSafetyDiagnostics.swift Sources/HanQ/SyntheticInputMarker.swift Sources/HanQ/DiagnosticArchiveFormat.swift Sources/HanQ/InputDiagnostics.swift Sources/HanQ/DiagnosticSharedStorage.swift Sources/HanQ/CommandFilter.swift Sources/HanQ/JamoComposer.swift Sources/HanQ/KoreanKeyboardLayout.swift Sources/HanQ/SafariInputActivation.swift Sources/HanQ/SourceSwitchBarrier.swift Sources/HanQ/SelectionPreservingSourceSwitch.swift "${test_sources[@]}" -o "$stage/tests"
hanq_test_run "$stage/tests" "$@"
if "$native"; then exit 0; fi

# Keep the manual-conversion history regression in ordinary build checks.
bash scripts/test-manual-edit-boundary.sh

# Preserve normal post-edit composition alongside existing recovery tests.
bash scripts/test-deletion-composition.sh

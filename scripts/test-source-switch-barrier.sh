#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/test-workspace.sh
stage=$(hanq_test_stage switch-barrier)
trap 'rm -rf "$stage"' EXIT
swiftc Sources/HanQ/KeyboardStateMirror.swift -module-cache-path .build/hanq/module-cache Sources/HanQ/InputFocusAccess.swift Sources/HanQ/InputDeliveryOrigin.swift Sources/HanQ/InputSourceAccess.swift Sources/HanQ/PhysicalLetterKeys.swift Sources/HanQ/Mismatch*.swift Sources/HanQ/OnsetInputGate.swift Sources/HanQ/OnsetSafetyDiagnostics.swift Sources/HanQ/SyntheticInputMarker.swift Sources/HanQ/InputDiagnostics.swift Sources/HanQ/CommandFilter.swift Sources/HanQ/JamoComposer.swift Sources/HanQ/KoreanKeyboardLayout.swift Sources/HanQ/SourceSwitchBarrier.swift Tests/SourceSwitchBarrier/main.swift -o "$stage/tests"
hanq_test_run "$stage/tests"

# Keep the manual-conversion history regression in ordinary build checks.
bash scripts/test-manual-edit-boundary.sh

# Preserve normal post-edit composition alongside existing recovery tests.
bash scripts/test-deletion-composition.sh

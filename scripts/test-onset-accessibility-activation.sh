#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/test-workspace.sh
stage=$(hanq_test_stage focus-activation)
trap 'rm -rf "$stage"' EXIT
swiftc -module-cache-path "$stage/module-cache" Sources/HanQ/OnsetAccessibilityActivation.swift Tests/OnsetRecovery/AccessibilityActivationPolicy/main.swift -o "$stage/policy"
hanq_test_run "$stage/policy"
swiftc -module-cache-path "$stage/module-cache" Sources/HanQ/KeyboardStateMirror.swift Sources/HanQ/JamoComposer.swift Sources/HanQ/InputFocusAccess.swift Sources/HanQ/InputSourceAccess.swift Sources/HanQ/PhysicalLetterKeys.swift Sources/HanQ/Onset*.swift Sources/HanQ/SyntheticInputMarker.swift Sources/HanQ/InputDiagnostics.swift Sources/HanQ/KoreanKeyboardLayout.swift Tests/OnsetRecovery/AccessibilityActivation/main.swift -o "$stage/integration"
hanq_test_run "$stage/integration"

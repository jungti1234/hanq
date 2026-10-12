#!/bin/bash
# Isolated own NSTextView with real Apple IMEs; restores selected/enabled sources.
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build/hanq
source scripts/test-workspace.sh
stage=$(hanq_test_stage onset-native)
trap 'rm -rf "$stage"' EXIT
swiftc Sources/HanQ/KeyboardStateMirror.swift Sources/HanQ/JamoComposer.swift -module-cache-path .build/hanq/module-cache Sources/HanQ/InputFocusAccess.swift Sources/HanQ/InputSourceAccess.swift Sources/HanQ/PhysicalLetterKeys.swift Sources/HanQ/Onset*.swift Sources/HanQ/InputDiagnostics.swift Sources/HanQ/KoreanKeyboardLayout.swift Tests/OnsetRecovery/Native/main.swift -o "$stage/native"
hanq_test_run "$stage/native"

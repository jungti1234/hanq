#!/bin/bash
# Owned NSTextView, real IMEs. Restores selected/enabled sources. No global taps.
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build/hanq
source scripts/test-workspace.sh
stage=$(hanq_test_stage onset-late-native)
trap 'rm -rf "$stage"' EXIT
swiftc -D HANQ_DIAGNOSTIC_TESTING Sources/HanQ/KeyboardStateMirror.swift -module-cache-path .build/hanq/module-cache Sources/HanQ/JamoComposer.swift Sources/HanQ/InputFocusAccess.swift Sources/HanQ/InputSourceAccess.swift Sources/HanQ/PhysicalLetterKeys.swift Sources/HanQ/Onset*.swift Sources/HanQ/SyntheticInputMarker.swift Sources/HanQ/DiagnosticArchiveFormat.swift Sources/HanQ/InputDiagnostics.swift Sources/HanQ/DiagnosticSharedStorage.swift Sources/HanQ/KoreanKeyboardLayout.swift Tests/OnsetRecovery/LateLayoutCases.swift Tests/OnsetRecovery/LateNative/main.swift -o "$stage/native"
hanq_test_run "$stage/native"

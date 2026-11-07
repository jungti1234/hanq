#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/test-workspace.sh
stage=$(hanq_test_stage witness-refresh)
trap 'rm -rf "$stage"' EXIT
mkdir -p .build/hanq/module-cache
sources=(Sources/HanQ/KeyboardStateMirror.swift Sources/HanQ/JamoComposer.swift Sources/HanQ/InputFocusAccess.swift Sources/HanQ/InputSourceAccess.swift Sources/HanQ/PhysicalLetterKeys.swift Sources/HanQ/Onset*.swift Sources/HanQ/SyntheticInputMarker.swift Sources/HanQ/InputDiagnostics.swift Sources/HanQ/KoreanKeyboardLayout.swift)
swiftc -D HANQ_DIAGNOSTIC_TESTING -module-cache-path .build/hanq/module-cache "${sources[@]}" Tools/InputTestRecorder/RecorderCore.swift Tests/OnsetRecovery/WitnessRefresh/main.swift -o "$stage/tests"
HANQ_EXPECT_REFRESH=1 hanq_test_run "$stage/tests" "$stage/result.json"
if [[ $# -gt 0 ]]; then
    [[ "$1" == /* && ! -e "$1" ]] || { echo 'Evidence output must be new.' >&2; exit 1; }
    mkdir -p "$1"
    cp "$stage/result.json" "$1/"
fi

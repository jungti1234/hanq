#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/test-workspace.sh
stage=$(hanq_test_stage onset-diagnostic-history)
evidence=${1:-}
if [[ -n "$evidence" ]]; then
    [[ "$evidence" == /* && ! -e "$evidence" ]] || { echo 'Evidence output must be new.' >&2; exit 1; }
fi
finish() {
    status=$?
    if [[ -n "$evidence" ]]; then
        mkdir -p "$evidence"
        for file in "$stage"/*.json; do
            if [[ -f "$file" ]]; then cp "$file" "$evidence/"; fi
        done
        printf '%s\n' "$status" > "$evidence/exit-code.txt"
    fi
    rm -rf "$stage"
    return "$status"
}
trap finish EXIT
mkdir -p .build/hanq/module-cache
sources=(Sources/HanQ/KeyboardStateMirror.swift Sources/HanQ/JamoComposer.swift Sources/HanQ/InputFocusAccess.swift Sources/HanQ/InputSourceAccess.swift Sources/HanQ/PhysicalLetterKeys.swift Sources/HanQ/Onset*.swift Sources/HanQ/SyntheticInputMarker.swift Sources/HanQ/InputDiagnostics.swift Sources/HanQ/KoreanKeyboardLayout.swift)
swiftc -D HANQ_DIAGNOSTIC_TESTING -module-cache-path .build/hanq/module-cache "${sources[@]}" Tools/InputTestRecorder/RecorderCore.swift Tests/OnsetRecovery/DiagnosticHistory/main.swift -o "$stage/tests"
hanq_test_run "$stage/tests" "$stage/capture.json"
python3 -B scripts/summarize-input-incident.py "$stage/capture.json" > "$stage/summary.json"

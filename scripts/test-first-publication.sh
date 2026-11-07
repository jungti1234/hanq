#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build/hanq/module-cache
source scripts/test-workspace.sh
stage=$(hanq_test_stage first-publication)
evidence=${1:-${HANQ_FIRST_PUBLICATION_EVIDENCE:-}}
if [[ -n "$evidence" ]]; then
    [[ "$evidence" == /* && ! -e "$evidence" ]] || { echo 'Evidence output must be a new absolute directory.' >&2; exit 1; }
fi
finish() {
    status=$?
    if [[ -n "$evidence" ]]; then
        mkdir -p "$evidence"
        if [[ -f "$stage/slow-result.json" ]]; then cp "$stage/slow-result.json" "$evidence/"; fi
        if [[ -d "$stage/engine" ]]; then cp -R "$stage/engine" "$evidence/"; fi
        printf '%s\n' "$status" > "$evidence/exit-code.txt"
    fi
    rm -rf "$stage"
    return "$status"
}
trap finish EXIT
sources=(Sources/HanQ/KeyboardStateMirror.swift Sources/HanQ/JamoComposer.swift Sources/HanQ/InputFocusAccess.swift Sources/HanQ/InputSourceAccess.swift Sources/HanQ/PhysicalLetterKeys.swift Sources/HanQ/Onset*.swift Sources/HanQ/SyntheticInputMarker.swift Sources/HanQ/InputDiagnostics.swift Sources/HanQ/KoreanKeyboardLayout.swift)
for group in SlowFirstPublication PublicationLifetime FirstPublicationDiagnostics; do
    swiftc -D HANQ_DIAGNOSTIC_TESTING -module-cache-path .build/hanq/module-cache "${sources[@]}" Tools/InputTestRecorder/RecorderCore.swift "Tests/OnsetRecovery/$group/main.swift" -o "$stage/$group"
done
HANQ_EXPECT_RETAINED_PROOF=1 HANQ_SLOW_PUBLICATION_RESULT="$stage/slow-result.json" hanq_test_run "$stage/SlowFirstPublication"
hanq_test_run "$stage/PublicationLifetime"
hanq_test_run "$stage/FirstPublicationDiagnostics" "$stage/engine"
for mode in fresh old missing normal; do
    python3 -B scripts/summarize-input-incident.py "$stage/engine/$mode.json" > "$stage/engine/$mode-summary.json"
done

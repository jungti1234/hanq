#!/bin/bash
# Explicit performance comparison; run outside the restricted AppKit sandbox.
# Product callbacks + injected snapshots only. No actual keys, AX reads or source changes.
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/test-workspace.sh
stage=$(hanq_test_stage diagnostics-impact)
trap 'rm -rf "$stage"' EXIT
mkdir -p .build/hanq/module-cache
output="${1:-.build/hanq/diagnostics-impact-$(date +%Y%m%d-%H%M%S)}"
compare_options=(--executable "$stage/impact-tests" --output "$output")
if [[ "${2:-}" == --capture-only ]]; then compare_options+=(--capture-only)
elif [[ $# -gt 1 ]]; then echo 'usage: test-diagnostics-impact.sh [output] [--capture-only]' >&2; exit 2; fi
swiftc -O -whole-module-optimization -D HANQ_DIAGNOSTIC_TESTING -target arm64-apple-macosx13.0 -module-cache-path .build/hanq/module-cache Sources/HanQ/KeyboardStateMirror.swift Sources/HanQ/InputFocusAccess.swift Sources/HanQ/InputDeliveryOrigin.swift Sources/HanQ/InputSourceAccess.swift Sources/HanQ/PhysicalLetterKeys.swift Sources/HanQ/Mismatch*.swift Sources/HanQ/OnsetInputGate.swift Sources/HanQ/OnsetSafetyDiagnostics.swift Sources/HanQ/InputDiagnostics.swift Sources/HanQ/CommandFilter.swift Sources/HanQ/JamoComposer.swift Sources/HanQ/KoreanKeyboardLayout.swift Tests/Diagnostics/Impact/main.swift -o "$stage/impact-tests"
python3 -B Tests/Diagnostics/Impact/compare.py "${compare_options[@]}"

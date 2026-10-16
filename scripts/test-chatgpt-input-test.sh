#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/test-workspace.sh
stage=$(hanq_test_stage auto-input)
trap 'rm -rf "$stage"' EXIT
swiftc -module-cache-path .build/hanq/module-cache Sources/HanQ/PhysicalLetterKeys.swift Sources/HanQ/JamoComposer.swift Sources/HanQ/KoreanKeyboardLayout.swift Tools/InputTestRecorder/AutoInputEngine.swift Tools/InputTestRecorder/AutoInputCases.swift Tests/InputTestRecorder/AutoEngine/main.swift -o "$stage/tests"
hanq_test_run "$stage/tests"
python3 -B Tests/InputTestRecorder/test_auto_summary.py

#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/test-workspace.sh
stage=$(hanq_test_stage write-budget)
trap 'rm -rf "$stage"' EXIT
swiftc -D HANQ_DIAGNOSTIC_TESTING -module-cache-path .build/hanq/module-cache Sources/HanQ/InputDiagnostics.swift Tools/InputTestRecorder/RecorderCore.swift Tests/Diagnostics/WriteBudget/main.swift -o "$stage/budget-tests"
hanq_test_run "$stage/budget-tests"

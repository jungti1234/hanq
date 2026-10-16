#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build/hanq/module-cache
source scripts/test-workspace.sh
stage=$(hanq_test_stage diagnostics)
trap 'rm -rf "$stage"' EXIT
swiftc -module-cache-path .build/hanq/module-cache Sources/HanQ/InputDiagnostics.swift Tests/Diagnostics/main.swift -o "$stage/diagnostics-tests"
hanq_test_run "$stage/diagnostics-tests"
hanq_test_run "$stage/diagnostics-tests" --diagnose-input "$stage/trace.log"
# Invalid/missing destinations must not evaluate messages or crash the caller.
hanq_test_run "$stage/diagnostics-tests" --expect-disabled --diagnose-input "$stage/missing/trace.log"
hanq_test_run "$stage/diagnostics-tests" --diagnose-input
swiftc -module-cache-path .build/hanq/module-cache Sources/HanQ/InputDiagnostics.swift Tests/Diagnostics/Incidents/main.swift -o "$stage/incident-tests"
hanq_test_run "$stage/incident-tests"
python3 -B Tests/Diagnostics/test_incident_summary.py

#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build/hanq/module-cache
source scripts/test-workspace.sh
stage=$(hanq_test_stage diagnostics)
trap 'rm -rf "$stage"' EXIT
swiftc -D HANQ_DIAGNOSTIC_TESTING -module-cache-path .build/hanq/module-cache Sources/HanQ/InputDiagnostics.swift Tests/Diagnostics/main.swift -o "$stage/diagnostics-tests"
hanq_test_run "$stage/diagnostics-tests"
hanq_test_run "$stage/diagnostics-tests" --diagnose-input "$stage/trace.log"
# Invalid/missing destinations must not evaluate messages or crash the caller.
hanq_test_run "$stage/diagnostics-tests" --expect-disabled --diagnose-input "$stage/missing/trace.log"
hanq_test_run "$stage/diagnostics-tests" --diagnose-input
swiftc -D HANQ_DIAGNOSTIC_TESTING -module-cache-path .build/hanq/module-cache Sources/HanQ/InputDiagnostics.swift Tests/Diagnostics/Incidents/main.swift -o "$stage/incident-tests"
hanq_test_run "$stage/incident-tests"
swiftc -D HANQ_DIAGNOSTIC_TESTING -module-cache-path .build/hanq/module-cache Sources/HanQ/InputDiagnostics.swift Tests/Diagnostics/Retention/main.swift -o "$stage/retention-tests"
hanq_test_run "$stage/retention-tests"
swiftc -D HANQ_DIAGNOSTIC_TESTING -module-cache-path .build/hanq/module-cache Sources/HanQ/InputDiagnostics.swift Tools/InputTestRecorder/RecorderCore.swift Tests/Diagnostics/Decisions/main.swift -o "$stage/decision-tests"
hanq_test_run "$stage/decision-tests"
swiftc -D HANQ_DIAGNOSTIC_TESTING -module-cache-path .build/hanq/module-cache Sources/HanQ/InputDiagnostics.swift Tools/InputTestRecorder/RecorderCore.swift Tests/Diagnostics/DecisionTiming/main.swift -o "$stage/decision-timing-tests"
hanq_test_run "$stage/decision-timing-tests"
swiftc -D HANQ_DIAGNOSTIC_TESTING -module-cache-path .build/hanq/module-cache Sources/HanQ/InputDiagnostics.swift Tools/InputTestRecorder/RecorderCore.swift Tests/Diagnostics/Observations/main.swift -o "$stage/observation-tests"
hanq_test_run "$stage/observation-tests"
swiftc -D HANQ_DIAGNOSTIC_TESTING -module-cache-path .build/hanq/module-cache Sources/HanQ/InputDiagnostics.swift Tools/InputTestRecorder/RecorderCore.swift Tests/Diagnostics/ObservationTiming/main.swift -o "$stage/observation-timing-tests"
hanq_test_run "$stage/observation-timing-tests"
swiftc -D HANQ_DIAGNOSTIC_TESTING -module-cache-path .build/hanq/module-cache Sources/HanQ/InputDiagnostics.swift Tools/InputTestRecorder/RecorderCore.swift Tests/Diagnostics/StorageStatus/main.swift -o "$stage/storage-status-tests"
hanq_test_run "$stage/storage-status-tests"
swiftc -D HANQ_DIAGNOSTIC_TESTING -module-cache-path .build/hanq/module-cache Sources/HanQ/InputDiagnostics.swift Tests/Diagnostics/Persistence/main.swift -o "$stage/persistence-tests"
hanq_test_run "$stage/persistence-tests"
swiftc -D HANQ_DIAGNOSTIC_TESTING -module-cache-path .build/hanq/module-cache Sources/HanQ/InputDiagnostics.swift Tools/InputTestRecorder/RecorderCore.swift Tests/Diagnostics/Shapes/main.swift -o "$stage/shape-tests"
hanq_test_run "$stage/shape-tests"
swiftc -D HANQ_DIAGNOSTIC_TESTING -module-cache-path .build/hanq/module-cache Sources/HanQ/InputDiagnostics.swift Tools/InputTestRecorder/RecorderCore.swift Tests/Diagnostics/CapturePreservation/main.swift -o "$stage/capture-preservation-tests"
hanq_test_run "$stage/capture-preservation-tests" "$stage/capture-preservation.json"
python3 -B scripts/summarize-input-incident.py "$stage/capture-preservation.json" > "$stage/capture-summary.json"
python3 -B Tests/Diagnostics/test_incident_summary.py

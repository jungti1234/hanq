#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build/hanq/module-cache
source scripts/test-workspace.sh
stage=$(hanq_test_stage onset-decisions)
trap 'rm -rf "$stage"' EXIT
swiftc -D HANQ_DIAGNOSTIC_TESTING -module-cache-path .build/hanq/module-cache Sources/HanQ/InputDiagnostics.swift Tools/InputTestRecorder/RecorderCore.swift Tests/Diagnostics/OnsetDecisions/main.swift -o "$stage/decisions"
hanq_test_run "$stage/decisions" "$stage/decisions.json"
python3 -B scripts/summarize-input-incident.py "$stage/decisions.json" > "$stage/summary.json"
python3 - "$stage/summary.json" <<'PY'
import json,sys
v=json.load(open(sys.argv[1]))
assert [r['reason'] for r in v['onset_decisions']]==['baseline_missing','publication_observed']
assert all(r['site'] in ['reservation','publication'] for r in v['onset_decisions'])
print('PASS onset decision summary matches preserved fixed metadata')
PY

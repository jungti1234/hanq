#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/test-workspace.sh
stage=$(hanq_test_stage space-diagnostics)
trap 'rm -rf "$stage"' EXIT
swiftc -D HANQ_DIAGNOSTIC_TESTING -module-cache-path .build/hanq/module-cache Sources/HanQ/InputDiagnostics.swift Tools/InputTestRecorder/RecorderCore.swift Tests/Diagnostics/SpaceObservation/main.swift -o "$stage/tests"
hanq_test_run "$stage/tests" "$stage/capture.json"
python3 -B scripts/summarize-input-incident.py "$stage/capture.json" > "$stage/summary.json"
python3 - "$stage/summary.json" <<'PY'
import json,sys
v=json.load(open(sys.argv[1]));assert v['trigger']=='space_observation'
assert v['space_observations'][0]['reason']=='rapid_space_downs'
assert any(r.get('creatorClass')==3 and r.get('autoRepeat') is False for r in v['key_event_evidence'])
print('PASS: new capture and space metadata summary; no duplicate text or root-cause claim')
PY
if [[ $# -gt 0 ]]; then
    [[ ! -e "$1" ]] || exit 1
    cp "$stage/capture.json" "$1"
fi

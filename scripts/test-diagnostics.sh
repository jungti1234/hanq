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
swiftc -D HANQ_DIAGNOSTIC_TESTING -module-cache-path .build/hanq/module-cache Sources/HanQ/InputDiagnostics.swift Tools/InputTestRecorder/RecorderCore.swift Tests/Diagnostics/RecoveryStart/main.swift -o "$stage/recovery-start-tests"
hanq_test_run "$stage/recovery-start-tests" "$stage/recovery-start.json"
python3 -B scripts/summarize-input-incident.py "$stage/recovery-start.json" > "$stage/recovery-start-summary.json"
python3 -B Tests/Diagnostics/test_incident_summary.py
swiftc -D HANQ_DIAGNOSTIC_TESTING -module-cache-path .build/hanq/module-cache Sources/HanQ/InputDiagnostics.swift Tools/InputTestRecorder/RecorderCore.swift Tests/Diagnostics/SwitchTimeline/main.swift -o "$stage/switch-timeline-tests"
hanq_test_run "$stage/switch-timeline-tests" "$stage/switch-timeline.json"
python3 -B scripts/summarize-input-incident.py "$stage/switch-timeline.json" > "$stage/switch-summary.json"
python3 - "$stage/switch-summary.json" <<'PY'
import json,sys
v=json.load(open(sys.argv[1]));r=v['switch_timelines'][0]
assert r['previous_key']['key_class_name']=='space'
assert r['previous_key']['os_relative_to_switch_us']==-10000
assert r['following_keys'][0]['os_relative_to_switch_us']==160000
assert r['following_keys'][0]['os_to_observation_us']==10000
assert r['changed_shapes'][0]['caret_preceding_class_name']=='hangul_syllable'
assert [h['stage'] for h in r['hud']]==['requested','ordered','first_appkit_draw']
print('PASS switch timeline end-to-end summary; selection/drawing are not IME receipt')
PY

swiftc -D HANQ_DIAGNOSTIC_TESTING -module-cache-path .build/hanq/module-cache Sources/HanQ/InputDiagnostics.swift Tools/InputTestRecorder/RecorderCore.swift Tests/Diagnostics/Export/main.swift -o "$stage/export-tests"
hanq_test_run "$stage/export-tests"

swiftc -D HANQ_DIAGNOSTIC_TESTING -module-cache-path .build/hanq/module-cache Sources/HanQ/InputDiagnostics.swift Tests/Diagnostics/Reboot/main.swift -o "$stage/reboot-tests"
hanq_test_run "$stage/reboot-tests"

swiftc -D HANQ_DIAGNOSTIC_TESTING -module-cache-path .build/hanq/module-cache Sources/HanQ/InputDiagnostics.swift Tools/InputTestRecorder/RecorderCore.swift Tests/Diagnostics/IndirectInfluence/main.swift -o "$stage/indirect-tests"
hanq_test_run "$stage/indirect-tests" "$stage/indirect.json"
python3 -B scripts/summarize-input-incident.py "$stage/indirect.json" > "$stage/indirect-summary.json"

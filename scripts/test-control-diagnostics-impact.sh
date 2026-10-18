#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
output=${1:?new output directory}
source scripts/test-workspace.sh
stage=$(hanq_test_stage control-impact)
trap 'rm -rf "$stage"' EXIT
mkdir -p .build/hanq/module-cache
swiftc -D HANQ_DIAGNOSTIC_TESTING -module-cache-path .build/hanq/module-cache Sources/HanQ/KeyboardStateMirror.swift Sources/HanQ/InputFocusAccess.swift Sources/HanQ/InputDeliveryOrigin.swift Sources/HanQ/InputSourceAccess.swift Sources/HanQ/InputSourceObserver.swift Sources/HanQ/PhysicalLetterKeys.swift Sources/HanQ/Mismatch*.swift Sources/HanQ/OnsetInputGate.swift Sources/HanQ/OnsetSafetyDiagnostics.swift Sources/HanQ/InputDiagnostics.swift Sources/HanQ/CommandFilter.swift Sources/HanQ/JamoComposer.swift Sources/HanQ/KoreanKeyboardLayout.swift Tests/Diagnostics/Controls/Impact/main.swift -o "$stage/tests"
python3 - "$stage/tests" "$output" <<'PY'
import json,pathlib,statistics,subprocess,sys
exe=pathlib.Path(sys.argv[1]);out=pathlib.Path(sys.argv[2]).resolve();out.mkdir(exist_ok=False,parents=True)
rows=[];added=[]
for pair in range(4):
 values={}
 for on in ([False,True] if pair%2==0 else [True,False]):
  name=f'{pair}-'+('on' if on else 'off');p=out/(name+'.json');cmd=[str(exe),str(p)]
  if on:cmd+=['--diagnose-input-incidents',str(out/name)]
  subprocess.run(cmd,check=True,cwd=exe.parent);value=json.loads(p.read_text());values[on]=value;rows.append(value)
 assert values[False]['outcome']==values[True]['outcome']
 assert values[True]['max_us']<50000
 added.append(values[True]['p99_us']-values[False]['p99_us'])
 print('PAIR',pair,'identical control outcomes; added p99 us',added[-1],flush=True)
assert statistics.median(added)<1000 and sum(x>=1000 for x in added)<2
summary=dict(pass_all=True,pairs=4,callbacks_per_mode=sum(v['callbacks'] for v in rows if v['diagnostics']),all_outcomes_identical=True,paired_added_p99_us=added,median_added_p99_us=statistics.median(added),maximum_on_us=max(v['max_us'] for v in rows if v['diagnostics']),queries_injected=True,physical_keys_tested=False,actual_tis_queries=False)
(out/'summary.json').write_text(json.dumps(summary,indent=2)+'\n');print('PASS control diagnostic ON/OFF comparison',flush=True)
PY

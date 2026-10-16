#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
destination="${1:?결과 JSON 경로를 지정하세요}"
[[ ! -e "$destination" ]] || exit 1
source scripts/test-workspace.sh
stage=$(hanq_test_stage auto-input-native)
trap 'rm -rf "$stage"' EXIT
swiftc -module-cache-path .build/hanq/module-cache Tools/InputTestRecorder/AutoInputEngine.swift Tools/InputTestRecorder/AutoInputCases.swift Tests/InputTestRecorder/NativeAuto/main.swift -o "$stage/tests"
hanq_test_run "$stage/tests" "$stage/results.json"
cp "$stage/results.json" "$destination"
python3 - "$destination" <<'PY'
import json,sys
r=json.load(open(sys.argv[1]));assert r['reason']=='completed' and r['restored'] and len(r['cases'])==100
assert all(c['bodyAndCaretMatched'] for c in r['cases'])
print('PASS: 100 owned local native IME cases; no global keys or ChatGPT control')
PY

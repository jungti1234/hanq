#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/test-workspace.sh
stage=$(hanq_test_stage shared-diagnostics)
# Preserve this run on failure for investigation; never touch existing evidence.
python3 - "$stage" <<'PY'
import os,pathlib,stat,sys
p=pathlib.Path(sys.argv[1]);s=p.lstat()
assert str(p.resolve())==str(p) and str(p).startswith('/private/tmp/hanq-')
assert stat.S_ISDIR(s.st_mode) and s.st_uid==os.getuid() and stat.S_IMODE(s.st_mode)==0o700
PY
swiftc -O -D HANQ_DIAGNOSTIC_TESTING -module-cache-path .build/hanq/module-cache Sources/HanQ/DiagnosticArchiveFormat.swift Sources/HanQ/InputDiagnostics.swift Sources/HanQ/DiagnosticSharedStorage.swift Sources/HanQ/DiagnosticReview.swift Tools/InputTestRecorder/RecorderCore.swift Tests/Diagnostics/SharedStorage/main.swift -o "$stage/shared-tests"
hanq_test_run "$stage/shared-tests"
python3 -B - "$stage/trace/Shared-v1" <<'PY'
import pathlib,sys
sys.path.insert(0,'scripts')
from shared_diagnostic import expand,read
from importlib.machinery import SourceFileLoader
summary=SourceFileLoader('incident_summary','scripts/summarize-input-incident.py').load_module()
files=[p for p in pathlib.Path(sys.argv[1]).glob('*.hqdiag') if read(p)[0].get('role',0)==0]
assert len(files)==4
for file in files: summary.summarize(expand(file))
print('PASS shared Python decoder and strict incident summary')
PY
printf 'Shared diagnostic test artifacts: %s\n' "$stage"

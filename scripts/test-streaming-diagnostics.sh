#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/test-workspace.sh
build_stage=$(hanq_test_stage streaming-build)
mkdir -p .build/hanq/module-cache
sources=(Sources/HanQ/DiagnosticArchiveFormat.swift Sources/HanQ/InputDiagnostics.swift Sources/HanQ/DiagnosticSharedStorage.swift Sources/HanQ/DiagnosticReview.swift)
swiftc -O -D HANQ_DIAGNOSTIC_TESTING -module-cache-path .build/hanq/module-cache "${sources[@]}" Tests/Diagnostics/StreamingStorage/main.swift -o "$build_stage/storage-tests"
clang -c Tests/Diagnostics/SharedPerformance/metrics.c -o "$build_stage/metrics.o"
swiftc -O -D HANQ_DIAGNOSTIC_TESTING -module-cache-path .build/hanq/module-cache "${sources[@]}" Tests/Diagnostics/Streaming/main.swift "$build_stage/metrics.o" -o "$build_stage/review-tests"
python3 - "$build_stage" <<'PY'
from pathlib import Path
import os,shutil,stat,subprocess,sys,tempfile
build=Path(sys.argv[1])
def stage(label):
    p=Path(tempfile.mkdtemp(prefix='hanq-streaming-'+label+'-',dir='/private/tmp'))
    assert p.resolve()==p and p.stat().st_uid==os.getuid() and stat.S_IMODE(p.stat().st_mode)==0o700
    return p
def run(folder,binary,*args):
    assert not binary.is_symlink()
    exe=folder/'tests';shutil.copy2(binary,exe)
    env=os.environ.copy();env['TMPDIR']=str(folder)
    subprocess.run([str(exe),*args],cwd=folder,env=env,check=True)
    print('Streaming artifacts:',folder,flush=True)
fixture=stage('storage');run(fixture,build/'storage-tests')
for fixture_name in ['maximum-input','pending-input']:
    for mode in ['load','zip']:
        folder=stage(fixture_name+'-'+mode);shutil.copytree(fixture/fixture_name,folder/'input')
        run(folder,build/'review-tests',mode)
PY

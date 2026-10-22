#!/bin/bash
# Prepare a human-only, owned native editor. Never posts keys or starts a step.
set -euo pipefail
cd "$(dirname "$0")/.."
record=${1:?사용법: prepare-long-document-physical.sh record.json 새-결과-디렉터리}
output=${2:?새 결과 디렉터리가 필요합니다}
python3 scripts/prepare-app-test.py check "$record"
[[ ! -e "$output" ]] || { echo '기존 결과를 덮어쓰지 않습니다.' >&2; exit 1; }
mkdir -p "$output"
output=$(cd "$output" && pwd)
source scripts/test-workspace.sh
stage=$(hanq_test_stage long-physical)
printf '%s\n' "$stage" > "$output/stage.txt"
app="$stage/HanQLongPhysical.app"
mkdir -p "$app/Contents/MacOS"
swiftc -target arm64-apple-macosx13.0 -module-cache-path .build/hanq/module-cache Tests/Support/OwnedInputSourceGuard.swift Tests/LongDocumentInput/ProductIdentity.swift Tests/LongDocumentInput/Support.swift Tests/LongDocumentInput/PhysicalMain.swift -o "$app/Contents/MacOS/HanQLongPhysical"
"$app/Contents/MacOS/HanQLongPhysical" --self-test > "$output/self-test.log"
python3 - "$app" "$record" "$stage" <<'PY'
import pathlib,plistlib,json,sys,hashlib
app,record,out=map(pathlib.Path,sys.argv[1:]);r=json.loads(record.read_text());identity=r['app']
assert r['status']=='permissions_ready' and r['permission_result']['ax'] and r['permission_result']['post']
exe=pathlib.Path(identity['path'])/'Contents/MacOS/HanQ'
assert hashlib.sha256(exe.read_bytes()).hexdigest()==identity['executable_sha256']
(out/'product.json').write_text(json.dumps(dict(pid=r['main_pid'],build=identity['build_number'],version=identity['release_version'],path=identity['path'],sha256=identity['executable_sha256'],record=str(record.resolve())),indent=2)+'\n')
(app/'Contents/Info.plist').write_bytes(plistlib.dumps(dict(CFBundleIdentifier='taek.in.hanq.long-document-physical',CFBundleExecutable='HanQLongPhysical',CFBundleName='HanQ long document physical',CFBundlePackageType='APPL',NSPrincipalClass='NSApplication')))
PY
cp "$stage/product.json" "$output/product.json"
codesign --force --sign - "$app"
swiftc -target arm64-apple-macosx13.0 -module-cache-path .build/hanq/module-cache Tests/Support/OwnedInputFocus.swift Tests/LongDocumentInput/ProductIdentity.swift Tests/Support/OwnedInputSourceControl.swift -o "$stage/source-control"
"$stage/source-control" "$stage" taek.in.hanq.long-document-physical "$app/Contents/MacOS/HanQLongPhysical" > "$output/source-control.log" 2>&1 &
printf '%s\n' "$!" > "$output/source-control-pid.txt"
python3 Tests/LongDocumentInput/fixture_cache.py wait-ready "$stage"
open -n "$app" --args "$stage"
printf '물리 키 시험 창 준비 완료: %s\n실행별 결과 위치: %s\n아직 키 입력·물리 검증은 실행하지 않았습니다.\n' "$output" "$stage"

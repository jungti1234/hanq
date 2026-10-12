#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
output=${1:?사용법: test-keyboard-state-native.sh 새-결과-디렉터리}
[[ ! -e "$output" ]] || { echo '기존 결과를 덮어쓰지 않습니다.' >&2; exit 1; }
mkdir -p "$output"
output=$(cd "$output" && pwd)
source scripts/test-workspace.sh
stage=$(hanq_test_stage keyboard-state-native)
trap 'touch "$stage/quit"; sleep .1; rm -rf "$stage"' EXIT
swiftc -parse-as-library -module-cache-path .build/hanq/module-cache Tests/KeyboardStateMirror/Native/actor.swift -o "$stage/actor"
for role in A B; do
    app="$stage/$role.app"
    mkdir -p "$app/Contents/MacOS"
    cp "$stage/actor" "$app/Contents/MacOS/Actor"
    python3 - "$app" "$role" <<'PY'
import pathlib,plistlib,sys
p=pathlib.Path(sys.argv[1])/'Contents/Info.plist'
identifier='taek.in.hanq.late-layout-fixture' if sys.argv[2]=='A' else 'taek.in.hanq.key-route-B'
p.write_bytes(plistlib.dumps(dict(CFBundleIdentifier=identifier,CFBundleExecutable='Actor',CFBundleName='HanQ Key Route '+sys.argv[2],CFBundlePackageType='APPL')))
PY
    codesign --force --sign - "$app"
done
swiftc -module-cache-path .build/hanq/module-cache Sources/HanQ/KeyboardStateMirror.swift Tests/OnsetRecovery/LateApp/PostedKeys.swift Tests/OnsetRecovery/LateApp/sender.swift -o "$stage/actual-sender"
swiftc -module-cache-path .build/hanq/module-cache Sources/HanQ/KeyboardStateMirror.swift Sources/HanQ/InputDeliveryOrigin.swift Tests/OnsetRecovery/LateApp/PostedKeys.swift Tests/KeyboardStateMirror/Native/main.swift -o "$stage/test"
status=0
"$stage/test" "$stage" > "$output/run.log" 2>&1 || status=$?
[[ ! -f "$stage/results.json" ]] || cp "$stage/results.json" "$output/results.json"
cat "$output/run.log"
exit "$status"

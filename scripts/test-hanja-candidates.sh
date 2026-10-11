#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build/hanq/module-cache
stage=$(mktemp -d "$PWD/.build/hanq/hanja-candidates.XXXXXX")
trap 'chmod -R u+rwX "$stage"; rm -rf "$stage"' EXIT
clang++ -fobjc-arc -framework Foundation -framework CoreServices Tests/HanjaCandidates/make-fixture.mm -o "$stage/make-fixture"
swiftc -module-cache-path .build/hanq/module-cache Sources/HanQ/HanjaCandidates.swift Tests/HanjaCandidates/main.swift -o "$stage/candidate-tests"
"$stage/candidate-tests" "$stage" "$stage/make-fixture"
app="$stage/HanjaCandidateTests.app"
mkdir -p "$app/Contents/MacOS"
swiftc -module-cache-path .build/hanq/module-cache Sources/HanQ/HanjaCandidateSelection.swift Sources/HanQ/HanjaCandidatePanel.swift Tests/HanjaCandidates/Native/main.swift -o "$app/Contents/MacOS/HanjaCandidateTests"
python3 - "$app" <<'PY'
import pathlib, plistlib, sys
app = pathlib.Path(sys.argv[1])
(app / 'Contents/Info.plist').write_bytes(plistlib.dumps({
    'CFBundleIdentifier': 'taek.in.hanq.candidate-tests', 'CFBundleExecutable': 'HanjaCandidateTests',
    'CFBundleName': 'HanjaCandidateTests', 'CFBundlePackageType': 'APPL',
    'InputMethodServerControllerClass': 'HanQCandidateInputController',
    'InputMethodConnectionName': 'taek.in.hanq.candidate-tests', 'LSUIElement': True}))
PY
codesign --force --sign - "$app"
"$app/Contents/MacOS/HanjaCandidateTests"

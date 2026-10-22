#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
output=${1:?새 빌드 디렉터리가 필요합니다}
[[ ! -e "$output" ]] || { echo '기존 시험 도구를 덮어쓰지 않습니다.' >&2; exit 1; }
mkdir -p "$output/LongDocument.app/Contents/MacOS"
python3 Tests/LongDocumentInput/fixture_cache.py freeze "$output"
swiftc -target arm64-apple-macosx13.0 -module-cache-path .build/hanq/module-cache Sources/HanQ/JamoComposer.swift Sources/HanQ/KoreanKeyboardLayout.swift Tests/OnsetRecovery/LateLayoutCases.swift Tests/Support/OwnedInputSourceGuard.swift Tests/LongDocumentInput/ProductIdentity.swift Tests/LongDocumentInput/Support.swift Tests/LongDocumentInput/AutoMain.swift -o "$output/LongDocument.app/Contents/MacOS/LongDocument"
swiftc -target arm64-apple-macosx13.0 -module-cache-path .build/hanq/module-cache Tests/Support/OwnedInputFocus.swift Sources/HanQ/KeyboardStateMirror.swift Tests/OnsetRecovery/LateApp/PostedKeys.swift Tests/LongDocumentInput/ProductIdentity.swift Tests/LongDocumentInput/sender.swift -o "$output/sender"
swiftc -target arm64-apple-macosx13.0 -module-cache-path .build/hanq/module-cache Tests/Support/OwnedInputFocus.swift Tests/LongDocumentInput/ProductIdentity.swift Tests/Support/OwnedInputSourceControl.swift -o "$output/source-control"
python3 - "$output" <<'PY'
from pathlib import Path
import plistlib,sys
p=Path(sys.argv[1])/'LongDocument.app/Contents/Info.plist'
p.write_bytes(plistlib.dumps(dict(CFBundleIdentifier='taek.in.hanq.long-document-fixture',CFBundleExecutable='LongDocument',CFBundleName='HanQ long document input',CFBundlePackageType='APPL',NSPrincipalClass='NSApplication')))
PY
codesign --force --sign - "$output/LongDocument.app"
python3 Tests/LongDocumentInput/fixture_cache.py create "$output"

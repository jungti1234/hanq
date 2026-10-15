#!/bin/bash
# Owned fixed editor; preparation never stops HanQ, resets TCC or selects a source.
set -euo pipefail
cd "$(dirname "$0")/.."
record=${1:?권한 사전 체크 기록이 필요합니다}
mode=${2:-}
[[ -z "$mode" || "$mode" == --cold ]] || { echo "두 번째 인자는 --cold만 지원합니다" >&2; exit 2; }
python3 scripts/prepare-app-test.py check "$record"
root=$(mktemp -d /private/tmp/hanq-paced-live.XXXXXX)
app="$root/PacedLiveFixture.app"
mkdir -p "$app/Contents/MacOS"
cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict><key>CFBundleExecutable</key><string>PacedLiveFixture</string><key>CFBundleIdentifier</key><string>taek.in.hanq.paced-live-fixture</string><key>CFBundleName</key><string>PacedLiveFixture</string><key>CFBundlePackageType</key><string>APPL</string><key>NSPrincipalClass</key><string>NSApplication</string></dict></plist>
PLIST
swiftc -module-cache-path .build/hanq/module-cache Sources/HanQ/InputSourceAccess.swift Tests/MismatchRecovery/PacedLive/main.swift -o "$app/Contents/MacOS/PacedLiveFixture"
cp "$record" "$root/preflight.json"
swiftc -module-cache-path .build/hanq/module-cache Sources/HanQ/InputSourceAccess.swift Sources/HanQ/KeyboardStateMirror.swift Tests/MismatchRecovery/PacedLive/probe.swift -o "$root/probe"
codesign --force --sign - "$app"
if [[ -n "$mode" ]]; then open -n "$app" --args "$root" "$mode"; else open -n "$app" --args "$root"; fi
echo "준비·실행 완료: $app"
echo "시험 루트: $root"
echo "고정 RKS 뒤 후속 K를 검사합니다. 기존 창과 입력 소스는 유지하세요."

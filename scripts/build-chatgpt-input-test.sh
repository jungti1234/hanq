#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
out="${1:-build/chatgpt-input-test}"
identity="${HANQ_SIGNING_IDENTITY:--}"
mkdir -p "$out" .build/hanq/module-cache
destination="$out/HanQ ChatGPT Input Test.app"
[[ ! -e "$destination" ]] || { echo "기존 앱을 덮어쓰지 않습니다: $destination" >&2; exit 1; }
stage=$(mktemp -d "$out/.auto-input-build.XXXXXX")
trap 'rm -rf "$stage"' EXIT
app="$stage/HanQ ChatGPT Input Test.app"
mkdir -p "$app/Contents/MacOS"
swiftc -module-cache-path .build/hanq/module-cache Tools/InputTestRecorder/RecorderCore.swift Tools/InputTestRecorder/AutoInputEngine.swift Tools/InputTestRecorder/AutoInputCases.swift Tools/InputTestRecorder/AutoInputDriver.swift Tools/InputTestRecorder/AutoHanQContext.swift Tools/InputTestRecorder/AutoMain.swift -o "$app/Contents/MacOS/HanQChatGPTInputTest"
cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>taek.in.hanq.chatgpt-input-test</string>
<key>CFBundleExecutable</key><string>HanQChatGPTInputTest</string>
<key>CFBundleName</key><string>HanQ ChatGPT Input Test</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>1.0</string>
<key>CFBundleVersion</key><string>4</string>
<key>NSHighResolutionCapable</key><true/>
<key>LSMinimumSystemVersion</key><string>13.0</string>
</dict></plist>
PLIST
codesign --force --sign "$identity" "$app"
codesign --verify --strict "$app"
[[ ! -e "$destination" ]] || exit 1
mv "$app" "$destination"
printf '자동 시험 앱: %s\n' "$destination"

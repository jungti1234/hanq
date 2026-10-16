#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
out="${1:-build/input-test-recorder}"
mkdir -p "$out" .build/hanq/module-cache
app="$out/HanQ Input Test Recorder.app"
if [[ -e "$app" ]]; then
    echo "기존 앱을 덮어쓰지 않습니다: $app" >&2
    exit 1
fi
mkdir -p "$app/Contents/MacOS"
swiftc -module-cache-path .build/hanq/module-cache Tools/InputTestRecorder/RecorderCore.swift Tools/InputTestRecorder/main.swift -o "$app/Contents/MacOS/HanQInputTestRecorder"
cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>taek.in.hanq.input-test-recorder</string>
<key>CFBundleExecutable</key><string>HanQInputTestRecorder</string>
<key>CFBundleName</key><string>HanQ Input Test Recorder</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>1.0</string>
<key>CFBundleVersion</key><string>2</string>
<key>NSHighResolutionCapable</key><true/>
<key>LSMinimumSystemVersion</key><string>13.0</string>
</dict></plist>
PLIST
codesign --force --sign - "$app"
codesign --verify --strict "$app"
printf '진단 앱: %s\n' "$app"

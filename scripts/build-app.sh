#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
source version.env
if [[ ! "$APP_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ || ! "$BUILD_NUMBER" =~ ^[1-9][0-9]*$ ]]; then
  echo 'version.env의 APP_VERSION 또는 BUILD_NUMBER가 잘못되었습니다.' >&2
  exit 1
fi
if [[ ! "$RELEASE_VERSION" =~ ^([0-9]+\.[0-9]+\.[0-9]+)(-beta\.[1-9][0-9]*)?$ ]] || [[ "${BASH_REMATCH[1]}" != "$APP_VERSION" ]]; then
  echo 'RELEASE_VERSION은 APP_VERSION 또는 APP_VERSION-beta.N 형식이어야 합니다.' >&2
  exit 1
fi
if [[ "${1:-}" == --print-version && $# -eq 1 ]]; then
  printf '%s (%s)\n' "$RELEASE_VERSION" "$BUILD_NUMBER"
  exit 0
fi
compiler=(swiftc)
output=build/HanQ.app
development=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --development) development=true; shift ;;
    --candidate) output=build/candidate/HanQ.app; shift ;;
    *) echo '사용법: bash scripts/build-app.sh [--print-version | --development | --candidate]' >&2; exit 1 ;;
  esac
done
if $development; then compiler+=(-D HANQ_DEVELOPMENT); fi
macos_minimum=13.0
build_arch=arm64
swift_target="${build_arch}-apple-macosx${macos_minimum}"
sparkle=$(bash scripts/prepare-sparkle.sh)
compiler+=(-F "$sparkle" -framework Sparkle -Xlinker -rpath -Xlinker @executable_path/../Frameworks)
process_status=0
if [[ "$output" == build/HanQ.app ]]; then
  pgrep -x HanQ >/dev/null || process_status=$?
else
  # Match the candidate executable only; the installed app may keep running.
  pgrep -f "^$PWD/$output/Contents/MacOS/HanQ([[:space:]]|$)" >/dev/null || process_status=$?
fi
if [[ $process_status -gt 1 ]]; then
  echo '실행 프로세스를 확인할 수 없어 교체를 중단합니다.' >&2
  exit 1
fi
if [[ $process_status -eq 0 ]]; then
  echo '한Q를 종료한 뒤 다시 빌드하세요. 실행 중인 앱은 교체하지 않습니다.' >&2
  exit 1
fi
mkdir -p .build/hanq/module-cache "$(dirname "$output")"
stage=$(mktemp -d "$PWD/.build/hanq/stage.XXXXXX")
trap 'rm -rf "$stage"' EXIT
app="$stage/HanQ.app"
if [[ ! -d Resources/HanQ.icon || ! -f Resources/HanQ.icns ]]; then
  echo '앱 아이콘 리소스가 없습니다: Resources/HanQ.icon 및 Resources/HanQ.icns' >&2
  exit 1
fi
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
"${compiler[@]}" -target "$swift_target" -module-cache-path .build/hanq/module-cache Sources/HanQ/*.swift -o "$app/Contents/MacOS/HanQ"
mkdir -p "$app/Contents/Frameworks"
ditto "$sparkle/Sparkle.framework" "$app/Contents/Frameworks/Sparkle.framework"
cp "$sparkle/LICENSE" "$app/Contents/Resources/Sparkle-LICENSE.txt"
cp -R Resources/. "$app/Contents/Resources/"
find "$app/Contents/Resources" -name .DS_Store -type f -delete
cp LICENSE "$app/Contents/Resources/LICENSE.txt"
swiftc -target "$swift_target" -module-cache-path .build/hanq/module-cache Sources/HanQ/JamoComposer.swift Sources/HanQ/KoreanKeyboardLayout.swift Sources/HanQ/HanjaReplacement.swift Sources/HanQ/CommandFilter.swift Sources/HanQ/InputSourceObserver.swift Tests/main.swift -o "$stage/filter-tests"
"$stage/filter-tests"
bash scripts/test-external-keyboards.sh
bash scripts/test-onset-recovery.sh
bash scripts/test-diagnostics.sh
bash scripts/test-lifecycle.sh
bash scripts/test-watchdog.sh
bash scripts/test-permission-monitor.sh
bash scripts/test-recovery.sh
bash scripts/test-update-policy.sh
previous_app="$output"
previous=unknown
if [[ -f "$previous_app/Contents/Info.plist" ]]; then
  previous=$(/usr/libexec/PlistBuddy -c 'Print CFBundleVersion' "$previous_app/Contents/Info.plist")
fi
cat > "$app/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>HanQ</string>
<key>CFBundleIdentifier</key><string>taek.in.hanq</string>
<key>CFBundleName</key><string>HanQ</string>
<key>CFBundleDisplayName</key><string>한Q</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>$APP_VERSION</string>
<key>CFBundleVersion</key><string>$BUILD_NUMBER</string>
<key>HanQReleaseVersion</key><string>$RELEASE_VERSION</string>
<key>LSMinimumSystemVersion</key><string>$macos_minimum</string>
<key>LSUIElement</key><true/>
<key>CFBundleIconFile</key><string>HanQ.icns</string>
<key>NSHumanReadableCopyright</key><string>© 2026 Taek In Jung</string>
<key>NSPrincipalClass</key><string>NSApplication</string>
<key>NSHighResolutionCapable</key><true/>
<key>CFBundleAllowMixedLocalizations</key><true/>
</dict></plist>
EOF
python3 scripts/configure-updates.py "$app/Contents/Info.plist"
python3 scripts/build-manifest.py "$app/Contents/Resources/HanQBuild.json" "$development"
plutil -lint "$app/Contents/Info.plist"
codesign --force --sign - "$app"
codesign --verify --deep --strict "$app"
cmp LICENSE "$app/Contents/Resources/LICENSE.txt"
if [[ -d "$previous_app" ]]; then
  mkdir -p .build/hanq/backups
  ditto "$previous_app" ".build/hanq/backups/HanQ-build-$previous-$(date +%s).app"
  mv "$previous_app" "$stage/previous.app"
fi
if ! mv "$app" "$output"; then
  if [[ -d "$stage/previous.app" ]]; then mv "$stage/previous.app" "$previous_app"; fi
  exit 1
fi
echo "Built $PWD/$output · $RELEASE_VERSION ($BUILD_NUMBER) · macOS $macos_minimum+ · $build_arch"

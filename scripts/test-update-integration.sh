#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
sparkle=$(bash scripts/prepare-sparkle.sh)
root="$PWD/.build/hanq/update-integration"
mkdir -p "$root" .build/hanq/module-cache
app="$root/HanQ Update Tests.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources" "$app/Contents/Frameworks"
sed '/^\/\/ MARK: Executable entry/,$d' Sources/HanQ/main.swift > "$root/AppDelegate.swift"
sources=()
for source in Sources/HanQ/*.swift; do
  [[ "$source" == Sources/HanQ/main.swift ]] || sources+=("$source")
done
swiftc -module-cache-path .build/hanq/module-cache -F "$sparkle" -framework Sparkle \
  -Xlinker -rpath -Xlinker @executable_path/../Frameworks \
  "${sources[@]}" "$root/AppDelegate.swift" Tests/UpdateIntegration/main.swift -o "$app/Contents/MacOS/HanQUpdateTests"
ditto "$sparkle/Sparkle.framework" "$app/Contents/Frameworks/Sparkle.framework"
# Ephemeral test key; never access production signing keys or publish a restriction.
swiftc -module-cache-path .build/hanq/module-cache Sources/HanQ/UpdatePolicy.swift Tests/UpdateIntegration/fixtures.swift -o "$root/make-fixtures"
"$root/make-fixtures" "$app"
codesign --force --sign - "$app"
"$app/Contents/MacOS/HanQUpdateTests" "$@"

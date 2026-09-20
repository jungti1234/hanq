#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build/hanq/module-cache
stage=$(mktemp -d "$PWD/.build/hanq/development-build.XXXXXX")
trap 'rm -rf "$stage"' EXIT
sed '/^\/\/ MARK: Executable entry/,$d' Sources/HanQ/main.swift > "$stage/AppDelegate.swift"
sparkle=$(bash scripts/prepare-sparkle.sh)
link=(-F "$sparkle" -framework Sparkle -Xlinker -rpath -Xlinker "$sparkle")
sources=()
for source in Sources/HanQ/*.swift; do
  [[ "$source" == Sources/HanQ/main.swift ]] || sources+=("$source")
done
swiftc "${link[@]}" -module-cache-path .build/hanq/module-cache "${sources[@]}" "$stage/AppDelegate.swift" Tests/DevelopmentBuild/main.swift -o "$stage/normal-tests"
"$stage/normal-tests"
swiftc "${link[@]}" -D HANQ_DEVELOPMENT -module-cache-path .build/hanq/module-cache "${sources[@]}" "$stage/AppDelegate.swift" Tests/DevelopmentBuild/main.swift -o "$stage/development-tests"
"$stage/development-tests"

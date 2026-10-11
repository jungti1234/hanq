#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build/hanq/module-cache
source scripts/test-workspace.sh
stage=$(hanq_test_stage development-build)
trap 'rm -rf "$stage"' EXIT
sed '/^\/\/ MARK: Executable entry/,$d' Sources/HanQ/main.swift > "$stage/AppDelegate.swift"
sparkle=$(bash scripts/prepare-sparkle.sh)
ditto "$sparkle/Sparkle.framework" "$stage/Sparkle.framework"
link=(-F "$stage" -framework Sparkle -Xlinker -rpath -Xlinker "$stage")
sources=()
for source in Sources/HanQ/*.swift; do
  [[ "$source" == Sources/HanQ/main.swift ]] || sources+=("$source")
done
swiftc "${link[@]}" -module-cache-path .build/hanq/module-cache "${sources[@]}" "$stage/AppDelegate.swift" Tests/DevelopmentBuild/main.swift -o "$stage/normal-tests"
hanq_test_run "$stage/normal-tests"
swiftc "${link[@]}" -D HANQ_DEVELOPMENT -module-cache-path .build/hanq/module-cache "${sources[@]}" "$stage/AppDelegate.swift" Tests/DevelopmentBuild/main.swift -o "$stage/development-tests"
hanq_test_run "$stage/development-tests"

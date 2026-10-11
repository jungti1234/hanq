#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/test-workspace.sh
stage=$(hanq_test_stage lifecycle)
trap 'rm -rf "$stage"' EXIT
# Exclude only the executable bootstrap to exercise the real AppDelegate.
sed '/^\/\/ MARK: Executable entry/,$d' Sources/HanQ/main.swift > "$stage/AppDelegate.swift"
sparkle=$(bash scripts/prepare-sparkle.sh)
ditto "$sparkle/Sparkle.framework" "$stage/Sparkle.framework"
link=(-F "$stage" -framework Sparkle -Xlinker -rpath -Xlinker "$stage")
sources=()
for source in Sources/HanQ/*.swift; do
  [[ "$source" == Sources/HanQ/main.swift ]] || sources+=("$source")
done
swiftc "${link[@]}" -module-cache-path .build/hanq/module-cache "${sources[@]}" "$stage/AppDelegate.swift" Tests/Lifecycle/main.swift -o "$stage/lifecycle-tests"
hanq_test_run "$stage/lifecycle-tests"

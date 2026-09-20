#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
stage=$(mktemp -d "$PWD/.build/hanq/lifecycle.XXXXXX")
trap 'rm -rf "$stage"' EXIT
# Exclude only the executable bootstrap to exercise the real AppDelegate.
sed '/^\/\/ MARK: Executable entry/,$d' Sources/HanQ/main.swift > "$stage/AppDelegate.swift"
sources=()
for source in Sources/HanQ/*.swift; do
  [[ "$source" == Sources/HanQ/main.swift ]] || sources+=("$source")
done
swiftc -module-cache-path .build/hanq/module-cache "${sources[@]}" "$stage/AppDelegate.swift" Tests/Lifecycle/main.swift -o "$stage/lifecycle-tests"
"$stage/lifecycle-tests"

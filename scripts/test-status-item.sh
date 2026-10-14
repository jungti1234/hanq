#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/test-workspace.sh
stage=$(hanq_test_stage status-item)
trap 'rm -rf "$stage"' EXIT
swiftc -target arm64-apple-macosx13.0 -module-cache-path .build/hanq/module-cache \
  Sources/HanQ/InputDiagnostics.swift Sources/HanQ/StatusItemController.swift \
  Sources/HanQ/MenuBarRecoveryNotice.swift \
  Tests/StatusItem/main.swift -o "$stage/status-item-tests"
cp Resources/HanQ-MenuBar-Template.pdf "$stage/icon.pdf"
# Some sandboxed AppKit launches exit before main produces any test output.
# Require the final assertion marker rather than mistaking exit 0 for a pass.
hanq_test_run "$stage/status-item-tests" "$stage/icon.pdf" > "$stage/result.txt"
cat "$stage/result.txt"
rg -q '^PASS: missing PDF has visible text fallback and accessibility metadata$' "$stage/result.txt"

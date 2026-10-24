#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/test-workspace.sh
stage=$(hanq_test_stage temporary-pasteboard)
trap 'rm -rf "$stage"' EXIT
swiftc -module-cache-path .build/hanq/module-cache Sources/HanQ/TemporaryPasteboard.swift Sources/HanQ/JamoPasteboard.swift Tests/TemporaryPasteboard/main.swift -o "$stage/tests"
hanq_test_run "$stage/tests"

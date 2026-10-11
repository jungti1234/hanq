#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/test-workspace.sh
stage=$(hanq_test_stage focus)
trap 'rm -rf "$stage"' EXIT
swiftc -module-cache-path .build/hanq/module-cache Sources/HanQ/InputFocusAccess.swift Tests/InputFocus/main.swift -o "$stage/tests"
hanq_test_run "$stage/tests"

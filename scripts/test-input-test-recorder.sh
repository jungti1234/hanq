#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/test-workspace.sh
stage=$(hanq_test_stage input-recorder)
trap 'rm -rf "$stage"' EXIT
swiftc -module-cache-path .build/hanq/module-cache Tools/InputTestRecorder/RecorderCore.swift Tests/InputTestRecorder/main.swift -o "$stage/tests"
hanq_test_run "$stage/tests"

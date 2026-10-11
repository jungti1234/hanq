#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/test-workspace.sh
stage=$(hanq_test_stage watchdog)
trap 'rm -rf "$stage"' EXIT
swiftc -module-cache-path .build/hanq/module-cache Sources/HanQ/InputSafetyWatchdog.swift Tests/Watchdog/main.swift -o "$stage/watchdog-tests"
hanq_test_run "$stage/watchdog-tests" healthy
hanq_test_run "$stage/watchdog-tests" disarmed
result=0
hanq_test_run "$stage/watchdog-tests" stalled || result=$?
[[ "$result" -eq 77 ]] || { echo "FAIL: stalled run loop exit status $result"; exit 1; }
echo 'PASS: stalled main thread exits from independent watchdog'

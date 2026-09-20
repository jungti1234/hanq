#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
stage=$(mktemp -d "$PWD/.build/hanq/watchdog.XXXXXX")
trap 'rm -rf "$stage"' EXIT
swiftc -module-cache-path .build/hanq/module-cache Sources/HanQ/InputSafetyWatchdog.swift Tests/Watchdog/main.swift -o "$stage/watchdog-tests"
"$stage/watchdog-tests" healthy
"$stage/watchdog-tests" disarmed
result=0
"$stage/watchdog-tests" stalled || result=$?
[[ "$result" -eq 77 ]] || { echo "FAIL: stalled run loop exit status $result"; exit 1; }
echo 'PASS: stalled main thread exits from independent watchdog'

#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
stage=$(mktemp -d "$PWD/.build/hanq/permission-tests.XXXXXX")
trap 'rm -rf "$stage"' EXIT
swiftc -module-cache-path .build/hanq/module-cache Sources/HanQ/InputDiagnostics.swift Sources/HanQ/FreshPermissionMonitor.swift Tests/PermissionMonitor/main.swift -o "$stage/permission-tests"
for mode in revoked missing-result stalled-launch launch-error wrong-token corrupt-result result-before-error stop; do
  "$stage/permission-tests" "$mode"
done

#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/test-workspace.sh
stage=$(hanq_test_stage permission-tests)
trap 'rm -rf "$stage"' EXIT
swiftc -module-cache-path .build/hanq/module-cache Sources/HanQ/InputDiagnostics.swift Sources/HanQ/FreshPermissionMonitor.swift Tests/PermissionMonitor/main.swift -o "$stage/permission-tests"
for mode in revoked missing-result stalled-launch launch-error wrong-token corrupt-result result-before-error stop; do
  hanq_test_run "$stage/permission-tests" "$mode"
done

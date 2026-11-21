#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/test-workspace.sh
stage=$(hanq_test_stage diagnostic-durability)
trap 'printf "Durability artifacts: %s\n" "$stage"' EXIT
swiftc -D HANQ_DIAGNOSTIC_TESTING -module-cache-path .build/hanq/module-cache Sources/HanQ/DiagnosticArchiveFormat.swift Sources/HanQ/InputDiagnostics.swift Sources/HanQ/DiagnosticSharedStorage.swift Sources/HanQ/DiagnosticReview.swift Sources/HanQ/PermissionRecovery.swift Tests/Diagnostics/Durability/main.swift -o "$stage/durability-tests"
hanq_test_run "$stage/durability-tests"

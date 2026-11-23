#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/test-workspace.sh
stage=$(hanq_test_stage diagnostic-pending)
mkdir -p .build/hanq/module-cache
swiftc -D HANQ_DIAGNOSTIC_TESTING -module-cache-path .build/hanq/module-cache Sources/HanQ/DiagnosticArchiveFormat.swift Tests/Support/LegacyDiagnosticFixture.swift Sources/HanQ/InputDiagnostics.swift Sources/HanQ/DiagnosticSharedStorage.swift Sources/HanQ/DiagnosticReview.swift Tests/Diagnostics/PendingRecovery/main.swift -o "$stage/tests"
hanq_test_run "$stage/tests"
printf 'Pending recovery artifacts: %s\n' "$stage"

#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/test-workspace.sh
stage=$(hanq_test_stage diagnostic-migration)
trap 'rm -rf "$stage"' EXIT
mkdir -p .build/hanq/module-cache
swiftc -D HANQ_DIAGNOSTIC_TESTING -module-cache-path .build/hanq/module-cache Sources/HanQ/DiagnosticArchiveFormat.swift Sources/HanQ/InputDiagnostics.swift Sources/HanQ/DiagnosticSharedStorage.swift Sources/HanQ/DiagnosticReview.swift Tests/Support/LegacyDiagnosticFixture.swift Tests/Diagnostics/Migration/main.swift -o "$stage/tests"
hanq_test_run "$stage/tests"

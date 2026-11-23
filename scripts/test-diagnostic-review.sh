#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/test-workspace.sh
stage=$(hanq_test_stage diagnostic-review)
trap 'rm -rf "$stage"' EXIT
mkdir -p .build/hanq/module-cache
swiftc -D HANQ_DIAGNOSTIC_TESTING -module-cache-path .build/hanq/module-cache Sources/HanQ/DiagnosticArchiveFormat.swift Tests/Support/LegacyDiagnosticFixture.swift Sources/HanQ/InputDiagnostics.swift Sources/HanQ/DiagnosticSharedStorage.swift Sources/HanQ/DiagnosticReview.swift Tests/DiagnosticReview/main.swift -o "$stage/tests"
hanq_test_run "$stage/tests"
swiftc -D HANQ_DIAGNOSTIC_TESTING -module-cache-path .build/hanq/module-cache Sources/HanQ/DiagnosticArchiveFormat.swift Tests/Support/LegacyDiagnosticFixture.swift Sources/HanQ/InputDiagnostics.swift Sources/HanQ/DiagnosticSharedStorage.swift Sources/HanQ/DiagnosticReview.swift Tests/DiagnosticReviewIntegration/main.swift -o "$stage/integration-tests"
cp scripts/summarize-input-incident.py "$stage/summarize-input-incident.py"
cp scripts/shared_diagnostic.py "$stage/shared_diagnostic.py"
hanq_test_run "$stage/integration-tests"
if [[ "${1:-}" == --ui ]]; then
    swiftc -D HANQ_DIAGNOSTIC_TESTING -module-cache-path .build/hanq/module-cache Sources/HanQ/DiagnosticArchiveFormat.swift Sources/HanQ/InputDiagnostics.swift Sources/HanQ/DiagnosticSharedStorage.swift Sources/HanQ/DiagnosticReview.swift Sources/HanQ/DiagnosticReviewController.swift Sources/HanQ/UserFacingText.swift Tests/Support/LegacyDiagnosticFixture.swift Tests/DiagnosticReviewUI/main.swift -o "$stage/ui-tests"
    cp Resources/HanQ-Logo.png "$stage/HanQ-Logo.png"
    hanq_test_run "$stage/ui-tests" "$stage/review.png"
    mkdir -p .build/hanq/diagnostic-review
    cp "$stage/review.png" .build/hanq/diagnostic-review/review.png
    cp "$stage/review-dark-summary.png" "$stage/review-light-environment.png" "$stage/review-warning.png" .build/hanq/diagnostic-review/
    cp "$stage/review-shared-collapsed.png" "$stage/review-shared-expanded.png" .build/hanq/diagnostic-review/
fi

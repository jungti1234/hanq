#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/test-workspace.sh
stage=$(hanq_test_stage source-rules)
trap 'rm -rf "$stage"' EXIT
swiftc -module-cache-path .build/hanq/module-cache Sources/HanQ/PhysicalLetterKeys.swift Tests/MismatchRecovery/Live/CapsTrial.swift Tests/MismatchRecovery/Live/TrialTrace.swift Tests/MismatchRecovery/LiveRules/main.swift -o "$stage/rules"
hanq_test_run "$stage/rules"

cp Tests/MismatchRecovery/Live/retry.py "$stage/retry.py"
cp Tests/MismatchRecovery/LiveRules/test_retry.py "$stage/test_retry.py"
hanq_test_run python3 "$stage/test_retry.py"

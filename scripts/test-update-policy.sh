#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build/hanq/module-cache
source scripts/test-workspace.sh
stage=$(hanq_test_stage update-policy)
trap 'rm -rf "$stage"' EXIT
swiftc -module-cache-path .build/hanq/module-cache Sources/HanQ/UpdatePolicy.swift Sources/HanQ/UpdatePolicyClient.swift Tests/UpdatePolicy/main.swift -o "$stage/policy-tests"
hanq_test_run "$stage/policy-tests"

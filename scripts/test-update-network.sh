#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build/hanq/module-cache
source scripts/test-workspace.sh
stage=$(hanq_test_stage update-network)
trap 'rm -rf "$stage"' EXIT
swiftc -module-cache-path .build/hanq/module-cache Sources/HanQ/UpdatePolicy.swift Sources/HanQ/UpdatePolicyClient.swift Tests/UpdateNetwork/main.swift -o "$stage/network-tests"
mkdir -p "$stage/updates"
cp updates/config.json "$stage/updates/"
hanq_test_run "$stage/network-tests"

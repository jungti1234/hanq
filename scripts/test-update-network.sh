#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build/hanq/module-cache
stage=$(mktemp -d "$PWD/.build/hanq/update-network.XXXXXX")
trap 'rm -rf "$stage"' EXIT
swiftc -module-cache-path .build/hanq/module-cache Sources/HanQ/UpdatePolicy.swift Sources/HanQ/UpdatePolicyClient.swift Tests/UpdateNetwork/main.swift -o "$stage/network-tests"
"$stage/network-tests"

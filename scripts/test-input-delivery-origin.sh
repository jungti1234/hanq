#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
stage=$(mktemp -d "$PWD/.build/hanq/input-origin.XXXXXX")
trap 'rm -rf "$stage"' EXIT
swiftc -module-cache-path .build/hanq/module-cache Sources/HanQ/InputDeliveryOrigin.swift Tests/InputDeliveryOrigin/main.swift -o "$stage/tests"
"$stage/tests"

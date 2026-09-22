#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build/hanq/module-cache
stage=$(mktemp -d "$PWD/.build/hanq/external-keyboards.XXXXXX")
trap 'rm -rf "$stage"' EXIT
swiftc -module-cache-path .build/hanq/module-cache Sources/HanQ/ExternalKeyboard*.swift Tests/ExternalKeyboard/main.swift -o "$stage/tests"
cp Resources/HanQ-Logo.png "$stage/HanQ-Logo.png"
"$stage/tests" "$@"

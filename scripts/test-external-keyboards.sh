#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build/hanq/module-cache
source scripts/test-workspace.sh
stage=$(hanq_test_stage external-keyboards)
trap 'rm -rf "$stage"' EXIT
swiftc -module-cache-path .build/hanq/module-cache Sources/HanQ/ExternalKeyboard*.swift Tests/ExternalKeyboard/main.swift -o "$stage/tests"
cp Resources/HanQ-Logo.png "$stage/HanQ-Logo.png"
hanq_test_run "$stage/tests" "$@"
if [[ -f "$stage/external-keyboard-setup.png" ]]; then
    cp "$stage/external-keyboard-setup.png" .build/hanq/external-keyboard-setup.png
fi

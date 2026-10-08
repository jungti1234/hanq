#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
stage=$(mktemp -d "$PWD/.build/hanq/selection-source-switch.XXXXXX")
trap 'rm -rf "$stage"' EXIT
swiftc -module-cache-path .build/hanq/module-cache Sources/HanQ/InputSourceAccess.swift Sources/HanQ/SelectionPreservingSourceSwitch.swift Tests/SelectionSourceSwitch/main.swift -o "$stage/tests"
"$stage/tests"

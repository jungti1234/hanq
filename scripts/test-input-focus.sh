#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
stage=$(mktemp -d "$PWD/.build/hanq/focus.XXXXXX")
trap 'rm -rf "$stage"' EXIT
swiftc -module-cache-path .build/hanq/module-cache Sources/HanQ/InputFocusAccess.swift Tests/InputFocus/main.swift -o "$stage/tests"
"$stage/tests"

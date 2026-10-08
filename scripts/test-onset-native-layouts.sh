#!/bin/bash
# Isolated own NSTextView with real Apple IMEs; restores selected/enabled sources.
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build/hanq
stage=$(mktemp -d "$PWD/.build/hanq/onset-native.XXXXXX")
trap 'rm -rf "$stage"' EXIT
swiftc -module-cache-path .build/hanq/module-cache Sources/HanQ/InputFocusAccess.swift Sources/HanQ/InputSourceAccess.swift Sources/HanQ/PhysicalLetterKeys.swift Sources/HanQ/Onset*.swift Sources/HanQ/InputDiagnostics.swift Sources/HanQ/KoreanKeyboardLayout.swift Tests/OnsetRecovery/Native/main.swift -o "$stage/native"
"$stage/native"

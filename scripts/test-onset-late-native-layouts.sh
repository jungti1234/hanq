#!/bin/bash
# Owned NSTextView, real IMEs. Restores selected/enabled sources. No global taps.
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build/hanq
stage=$(mktemp -d "$PWD/.build/hanq/onset-late-native.XXXXXX")
trap 'rm -rf "$stage"' EXIT
swiftc -module-cache-path .build/hanq/module-cache Sources/HanQ/JamoComposer.swift Sources/HanQ/InputFocusAccess.swift Sources/HanQ/InputSourceAccess.swift Sources/HanQ/PhysicalLetterKeys.swift Sources/HanQ/Onset*.swift Sources/HanQ/InputDiagnostics.swift Sources/HanQ/KoreanKeyboardLayout.swift Tests/OnsetRecovery/LateLayoutCases.swift Tests/OnsetRecovery/LateNative/main.swift -o "$stage/native"
"$stage/native"

#!/bin/bash
# Real IMEs, isolated own text view. Temporarily enabled sources are restored.
set -euo pipefail
cd "$(dirname "$0")/.."
stage=$(mktemp -d "$PWD/.build/hanq/mismatch-native.XXXXXX")
trap 'rm -rf "$stage"' EXIT
swiftc -module-cache-path .build/hanq/module-cache Sources/HanQ/InputFocusAccess.swift Sources/HanQ/InputDeliveryOrigin.swift Sources/HanQ/InputSourceAccess.swift Sources/HanQ/PhysicalLetterKeys.swift Sources/HanQ/Mismatch*.swift Sources/HanQ/OnsetInputGate.swift Sources/HanQ/OnsetSafetyDiagnostics.swift Sources/HanQ/InputDiagnostics.swift Sources/HanQ/CommandFilter.swift Sources/HanQ/JamoComposer.swift Sources/HanQ/KoreanKeyboardLayout.swift Tests/MismatchRecovery/Native/main.swift -o "$stage/native"
"$stage/native"

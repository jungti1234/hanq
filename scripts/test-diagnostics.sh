#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build/hanq/module-cache
stage=$(mktemp -d "$PWD/.build/hanq/diagnostics.XXXXXX")
trap 'rm -rf "$stage"' EXIT
swiftc -module-cache-path .build/hanq/module-cache Sources/HanQ/InputDiagnostics.swift Tests/Diagnostics/main.swift -o "$stage/diagnostics-tests"
"$stage/diagnostics-tests"
"$stage/diagnostics-tests" --diagnose-input "$stage/trace.log"
# Invalid/missing destinations must not evaluate messages or crash the caller.
"$stage/diagnostics-tests" --expect-disabled --diagnose-input "$stage/missing/trace.log"
"$stage/diagnostics-tests" --diagnose-input

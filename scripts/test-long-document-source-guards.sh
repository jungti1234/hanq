#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/test-workspace.sh
stage=$(hanq_test_stage owned-source)
trap 'rm -rf "$stage"' EXIT
for mode in default optimized; do
  flags=(-Onone)
  if [[ "$mode" == optimized ]]; then flags=(-O -whole-module-optimization); fi
  swiftc "${flags[@]}" -D OWNED_SOURCE_CONTROL_TESTING -target arm64-apple-macosx13.0 -module-cache-path .build/hanq/module-cache Tests/Support/OwnedInputSourceControl.swift Tests/Support/OwnedInputSourceGuard.swift Tests/LongDocumentInput/Support.swift Tests/LongDocumentInput/SourceGuardTests.swift -o "$stage/test-$mode"
  hanq_test_run "$stage/test-$mode"
done

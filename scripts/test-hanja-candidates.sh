#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build/hanq/module-cache
stage=$(mktemp -d "$PWD/.build/hanq/hanja-candidates.XXXXXX")
trap 'chmod -R u+rwX "$stage"; rm -rf "$stage"' EXIT
clang++ -fobjc-arc -framework Foundation -framework CoreServices Tests/HanjaCandidates/make-fixture.mm -o "$stage/make-fixture"
swiftc -module-cache-path .build/hanq/module-cache Sources/HanQ/HanjaCandidates.swift Tests/HanjaCandidates/main.swift -o "$stage/candidate-tests"
"$stage/candidate-tests" "$stage" "$stage/make-fixture"

#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build/hanq/tools .build/hanq/module-cache
binary=.build/hanq/tools/policy-tool
if [[ ! -x "$binary" || Tools/UpdatePolicy/main.swift -nt "$binary" || Sources/HanQ/UpdatePolicy.swift -nt "$binary" ]]; then
  swiftc -module-cache-path .build/hanq/module-cache Sources/HanQ/UpdatePolicy.swift Tools/UpdatePolicy/main.swift -o "$binary"
fi
exec "$binary" "$@"

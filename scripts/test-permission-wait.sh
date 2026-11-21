#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/test-workspace.sh
stage=$(hanq_test_stage permission-wait)
# Keep the new trial's failure or success evidence when an output was requested.
cleanup() {
  if [[ -n "${HANQ_TEST_RESULT_DIR:-}" ]]; then
    mkdir -p "$HANQ_TEST_RESULT_DIR"
    [[ ! -d "$stage/incidents" ]] || ditto "$stage/incidents" "$HANQ_TEST_RESULT_DIR/incidents"
    [[ ! -f "$stage/result.json" ]] || cp "$stage/result.json" "$HANQ_TEST_RESULT_DIR/result.json"
  fi
  rm -rf "$stage"
}
trap cleanup EXIT
sed '/^\/\/ MARK: Executable entry/,$d' Sources/HanQ/main.swift > "$stage/AppDelegate.swift"
sparkle=$(bash scripts/prepare-sparkle.sh)
ditto "$sparkle/Sparkle.framework" "$stage/Sparkle.framework"
sources=()
for source in Sources/HanQ/*.swift; do
  [[ "$source" == Sources/HanQ/main.swift ]] || sources+=("$source")
done
swiftc -F "$stage" -framework Sparkle -Xlinker -rpath -Xlinker "$stage" \
  -module-cache-path .build/hanq/module-cache "${sources[@]}" "$stage/AppDelegate.swift" \
  Tests/PermissionWait/main.swift -o "$stage/permission-wait-tests"
hanq_test_run "$stage/permission-wait-tests" --preserve-input-incidents "$stage/incidents"

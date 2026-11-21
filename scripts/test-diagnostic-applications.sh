#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/test-workspace.sh
stage=$(hanq_test_stage diagnostic-applications)
app="$stage/DiagnosticApplications.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources" .build/hanq/module-cache
cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>DiagnosticApplications</string>
<key>CFBundleIdentifier</key><string>test.hanq.diagnostic-apps</string>
<key>CFBundleName</key><string>Diagnostic Applications Test</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>1.2.3</string>
<key>CFBundleVersion</key><string>437</string>
<key>LSUIElement</key><true/>
</dict></plist>
PLIST
swiftc -D HANQ_DIAGNOSTIC_TESTING -module-cache-path .build/hanq/module-cache Sources/HanQ/DiagnosticArchiveFormat.swift Sources/HanQ/InputDiagnostics.swift Sources/HanQ/DiagnosticSharedStorage.swift Sources/HanQ/DiagnosticReview.swift Sources/HanQ/DiagnosticReviewController.swift Sources/HanQ/UserFacingText.swift Tools/InputTestRecorder/RecorderCore.swift Tests/Diagnostics/Applications/main.swift -o "$app/Contents/MacOS/DiagnosticApplications"
cp Resources/HanQ-Logo.png "$app/Contents/Resources/"
codesign --force --sign - "$app"
python3 - "$stage" <<'PY'
from pathlib import Path
import os, stat, sys
root=Path(sys.argv[1])
assert root.parent==Path('/private/tmp') and root.resolve()==root
assert root.stat().st_uid==os.getuid() and stat.S_IMODE(root.stat().st_mode)==0o700
assert all(not p.is_symlink() for p in root.rglob('*'))
PY
hanq_test_run "$app/Contents/MacOS/DiagnosticApplications"
python3 -B Tests/Diagnostics/Applications/summary.py "$stage/capture.json" "$stage/summary.json"
if [[ -n "${HANQ_TEST_RESULT_DIR:-}" ]]; then
  mkdir -p "$HANQ_TEST_RESULT_DIR"
  cp "$stage/metrics.json" "$stage/applications-preview.png" "$stage/applications.zip" "$stage/capture.json" "$stage/summary.json" "$HANQ_TEST_RESULT_DIR/"
fi

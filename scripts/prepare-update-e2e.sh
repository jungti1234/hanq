#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
sparkle=$(bash scripts/prepare-sparkle.sh)
mode="${1:-normal}"
[[ "$mode" == normal || "$mode" == --required ]] || { echo 'Usage: prepare-update-e2e.sh [--required]' >&2; exit 1; }
root="$PWD/.build/hanq/update-e2e"
[[ "$mode" != --required ]] || root="$PWD/.build/hanq/update-required-e2e"
[[ -f "$root/port" ]] || { echo 'Start Tests/UpdateEndToEnd/server.py first' >&2; exit 1; }
if [[ -e "$root/installed/HanQ Update E2E.app" || -e "$root/server/update.dmg" ]]; then
  echo 'Existing test run found. Stop the test app/server and move .build/hanq/update-e2e before starting a fresh run.' >&2
  exit 1
fi
mkdir -p "$root/new" "$root/installed" "$root/server" .build/hanq/module-cache
swiftc -parse-as-library -module-cache-path .build/hanq/module-cache Sources/HanQ/UpdatePolicy.swift Tests/UpdateEndToEnd/key.swift -o "$root/make-key"
"$root/make-key" "$root/test-signing.key" "$root/required.json" > "$root/public-key"
swiftc -module-cache-path .build/hanq/module-cache -F "$sparkle" -framework Sparkle \
  -Xlinker -rpath -Xlinker @executable_path/../Frameworks Sources/HanQ/AppUpdater.swift Sources/HanQ/UpdatePolicy.swift \
  Sources/HanQ/UpdatePolicyClient.swift Tests/UpdateEndToEnd/main.swift -o "$root/HanQUpdateE2E"
python3 - "$root" "$sparkle" "$mode" <<'PY'
import json, plistlib, shutil, subprocess, sys
from pathlib import Path
root, sparkle = map(Path, sys.argv[1:3])
required = sys.argv[3] == "--required"
key=(root/'public-key').read_text().strip()
port=int((root/'port').read_text())
for folder, version in [('installed','1'), ('new','2')]:
 app=root/folder/'HanQ Update E2E.app'
 (app/'Contents/MacOS').mkdir(parents=True, exist_ok=True)
 (app/'Contents/Resources/Config.bundle/Contents').mkdir(parents=True, exist_ok=True)
 (app/'Contents/Frameworks').mkdir(exist_ok=True)
 shutil.copy2(root/'HanQUpdateE2E',app/'Contents/MacOS/HanQUpdateE2E')
 subprocess.run(['ditto',str(sparkle/'Sparkle.framework'),str(app/'Contents/Frameworks/Sparkle.framework')],check=True)
 info=dict(CFBundleIdentifier='taek.in.hanq.required-tests' if required else 'taek.in.hanq.sparkle-tests',CFBundleName='HanQ Update E2E',
           CFBundleExecutable='HanQUpdateE2E',CFBundlePackageType='APPL',CFBundleVersion=version,
           CFBundleShortVersionString='0.1.0',HanQReleaseVersion='0.1.0-beta.'+version,
           NSPrincipalClass='NSApplication',CFBundleAllowMixedLocalizations=True,
           LSMinimumSystemVersion='13.0',SUPublicEDKey=key,SUFeedURL=f'http://127.0.0.1:{port}/appcast.xml',
           SUEnableAutomaticChecks=False,SUAllowsAutomaticUpdates=False,SUEnableSystemProfiling=False,
           SUEnableInstallerLauncherService=True,SUVerifyUpdateBeforeExtraction=True,
           NSAppTransportSecurity={'NSAllowsArbitraryLoads':True},
           TestResultPath=str(root/'result.json'), TestRequiredPolicy=required)
 shutil.copy2(root/'required.json',app/'Contents/Resources/required.json')
 with (app/'Contents/Info.plist').open('wb') as f: plistlib.dump(info,f)
 config=dict(info,SUFeedURL='https://jungti1234.github.io/hanq/appcast.xml',
             HanQPolicyURL='https://jungti1234.github.io/hanq/policy.json',HanQPolicyPublicKey=key)
 with (app/'Contents/Resources/Config.bundle/Contents/Info.plist').open('wb') as f: plistlib.dump(config,f)
 subprocess.run(['codesign','--force','--sign','-',str(app)],check=True)
 subprocess.run(['codesign','--verify','--deep','--strict',str(app)],check=True)
PY
hdiutil create -quiet -srcfolder "$root/new" -volname 'HanQ Update Test' -fs APFS -format ULFO "$root/server/update.dmg"
"$sparkle/bin/sign_update" --ed-key-file "$root/test-signing.key" -p "$root/server/update.dmg" > "$root/signature"
python3 - "$root" <<'PY'
from pathlib import Path
import sys
root=Path(sys.argv[1]); port=int((root/'port').read_text()); signature=(root/'signature').read_text().strip()
length=(root/'server/update.dmg').stat().st_size
xml=f'''<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"><channel><title>한Q 별도 업데이트 테스트</title><item><title>테스트 빌드 2</title><sparkle:version>2</sparkle:version><sparkle:shortVersionString>0.1.0-beta.2</sparkle:shortVersionString><sparkle:channel>beta</sparkle:channel><sparkle:minimumSystemVersion>13.0</sparkle:minimumSystemVersion><enclosure url="http://127.0.0.1:{port}/update.dmg" sparkle:edSignature="{signature}" length="{length}" type="application/octet-stream" /></item></channel></rss>'''
(root/'server/appcast.xml').write_text(xml)
(root/'valid-appcast.xml').write_text(xml)
PY
printf 'Ready: %s\n' "$root/installed/HanQ Update E2E.app"

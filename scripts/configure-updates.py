#!/usr/bin/env python3
"""Embed only validated public configuration. No environment secrets are consumed."""
import base64
import json
import plistlib
import sys
from pathlib import Path
from urllib.parse import urlparse

config = json.loads(Path('updates/config.json').read_text())
plist_path = Path(sys.argv[1])
with plist_path.open('rb') as source:
    plist = plistlib.load(source)
for name in ('feedURL', 'policyURL'):
    url = urlparse(config[name])
    if url.scheme != 'https' or url.netloc != 'jungti1234.github.io' or not url.path.startswith('/hanq/'):
        raise SystemExit(f'Invalid {name}')
for name in ('sparklePublicKey', 'policyPublicKey'):
    if len(base64.b64decode(config[name], validate=True)) != 32:
        raise SystemExit(f'Invalid {name}')
plist.update(SUFeedURL=config['feedURL'], SUPublicEDKey=config['sparklePublicKey'],
             HanQPolicyURL=config['policyURL'], HanQPolicyPublicKey=config['policyPublicKey'],
             SUEnableInstallerLauncherService=True, SUAllowsAutomaticUpdates=False,
             SUEnableSystemProfiling=False, SUScheduledCheckInterval=86400,
             SUVerifyUpdateBeforeExtraction=True)
# Sparkle owns the opt-in prompt and persists the user's automatic-check choice.
with plist_path.open('wb') as target:
    plistlib.dump(plist, target, sort_keys=False)

#!/usr/bin/env python3
"""Record content identity without secrets or private documents."""
import hashlib
import json
import subprocess
import sys
from pathlib import Path


def source_hashes():
    paths = set(Path('Sources').rglob('*.swift')) | set(Path('Resources').rglob('*'))
    paths |= {Path('LICENSE'), Path('version.env'), Path('updates/config.json'),
              Path('scripts/build-app.sh'), Path('scripts/configure-updates.py'),
              Path('scripts/prepare-sparkle.sh'), Path('scripts/build-manifest.py')}
    return {str(p): hashlib.sha256(p.read_bytes()).hexdigest() for p in sorted(paths) if p.is_file() and p.name != '.DS_Store'}


if __name__ == '__main__':
    output = Path(sys.argv[1])
    data = {'schemaVersion': 1, 'development': sys.argv[2] == 'true',
            'sourceCommit': subprocess.check_output(['git', 'rev-parse', 'HEAD'], text=True).strip(),
            'sourceSHA256': source_hashes()}
    output.write_text(json.dumps(data, indent=2) + '\n')

#!/usr/bin/env python3
"""Build a separate Finder design preview; never replace a release artifact."""
import argparse
import hashlib
import json
from pathlib import Path
import plistlib
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / '.build/dmg-design-tools'))

def run(*args):
    subprocess.run([str(a) for a in args], check=True, cwd=ROOT)

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--app', type=Path, default=ROOT / 'build/candidate/HanQ.app')
    parser.add_argument('--output', type=Path, default=ROOT / 'dist/dmg-design')
    args = parser.parse_args()
    app = args.app.resolve(); output = args.output.resolve()
    if output.exists():
        parser.error('Output already exists; use a fresh preview directory.')
    try:
        import dmgbuild
    except ImportError:
        parser.error('Install packaging/dmg/requirements.txt into .build/dmg-design-tools first.')
    info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
    if app.name != 'HanQ.app' or info['CFBundleIdentifier'] != 'taek.in.hanq':
        parser.error('Expected an unchanged HanQ.app bundle.')
    version, build = info['HanQReleaseVersion'], info['CFBundleVersion']
    if any('/' in str(v) or '\\' in str(v) for v in [version, build]):
        parser.error('Invalid release identity.')
    run('codesign', '--verify', '--deep', '--strict', app)
    output.mkdir(parents=True)
    with tempfile.TemporaryDirectory(prefix='dmg-art-', dir=ROOT / '.build/hanq') as stage:
        renderer = Path(stage) / 'render-background'
        run('swiftc', '-module-cache-path', ROOT / '.build/hanq/module-cache',
            ROOT / 'packaging/dmg/render-background.swift', '-o', renderer)
        run(renderer, ROOT / 'Resources/HanQ-Logo.png', output, version, build)
    dmg = output / f'HanQ-{version}-build{build}-design-preview.dmg'
    # Finder needs a native bookmark on current macOS; mac_alias's synthetic
    # bookmark can fail URL resolution after the image is mounted.
    from dmgbuild import core
    from mac_alias import Bookmark
    class NativeBookmark:
        @staticmethod
        def for_file(path):
            data = subprocess.check_output([
                'swift', '-module-cache-path', str(ROOT / '.build/hanq/module-cache'),
                '-e', 'import Foundation; let u = URL(fileURLWithPath: CommandLine.arguments[1]); '
                'let d = try u.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil); '
                'FileHandle.standardOutput.write(d)', str(path)])
            return Bookmark.from_bytes(data)
    original_bookmark = core.Bookmark
    try:
        core.Bookmark = NativeBookmark
        dmgbuild.build_dmg(str(dmg), f'HanQ {version}',
            settings_file=str(ROOT / 'packaging/dmg/settings.py'),
            defines={'app': str(app), 'background': str(output / 'background.tiff')})
    finally:
        core.Bookmark = original_bookmark
    run('hdiutil', 'verify', dmg)
    digest = hashlib.sha256(dmg.read_bytes()).hexdigest()
    (output / 'SHA256SUMS').write_text(f'{digest}  {dmg.name}\n')
    (output / 'preview.json').write_text(json.dumps({'version': version, 'build': build,
        'previewOnly': True, 'dmg': dmg.name, 'sha256': digest,
        'note': 'Not signed for Sparkle or uploaded; release verification required before distribution.'}, indent=2)+'\n')
    print(dmg)

if __name__ == '__main__':
    main()

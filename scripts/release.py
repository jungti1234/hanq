#!/usr/bin/env python3
"""Prepare immutable local release candidates. Draft creation is an explicit command."""
import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import tempfile
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parent.parent
os.chdir(ROOT)
SPARKLE_NS = 'http://www.andymatuschak.org/xml-namespaces/sparkle'
ET.register_namespace('sparkle', SPARKLE_NS)


def run(*args):
    return subprocess.check_output([str(x) for x in args], text=True).strip()


def sha(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def source_hashes():
    spec = importlib.util.spec_from_file_location('manifest', ROOT / 'scripts/build-manifest.py')
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module.source_hashes()


def prepare(app):
    app = app.resolve()
    with (app / 'Contents/Info.plist').open('rb') as f:
        info = plistlib.load(f)
    identity = json.loads((app / 'Contents/Resources/HanQBuild.json').read_text())
    if identity['development'] or identity['sourceSHA256'] != source_hashes():
        raise SystemExit('Candidate is a development build or does not match current source; rebuild it.')
    version = info['HanQReleaseVersion']
    build = info['CFBundleVersion']
    if info['CFBundleIdentifier'] != 'taek.in.hanq' or not re.fullmatch(r'\d+\.\d+\.\d+(-beta\.[1-9]\d*)?', version) or not re.fullmatch(r'[1-9]\d*', build):
        raise SystemExit('Invalid release identity')
    if run('lipo', '-archs', app / 'Contents/MacOS/HanQ') != 'arm64':
        raise SystemExit('Unexpected architecture')
    run('codesign', '--verify', '--deep', '--strict', app)
    sparkle = Path(run('bash', 'scripts/prepare-sparkle.sh'))
    if run(sparkle / 'bin/generate_keys', '--account', 'taek.in.hanq', '-p') != info['SUPublicEDKey']:
        raise SystemExit('Signing key does not match the candidate public key')
    destination = ROOT / 'dist' / f'{version}-build{build}'
    if destination.exists():
        raise SystemExit(f'Refusing to overwrite existing candidate: {destination}')
    destination.parent.mkdir(exist_ok=True)
    stage = Path(tempfile.mkdtemp(prefix='release.', dir=ROOT / '.build/hanq'))
    try:
        payload = stage / 'payload'; payload.mkdir()
        run('ditto', app, payload / 'HanQ.app')
        (payload / 'Applications').symlink_to('/Applications')
        output = stage / 'output'; output.mkdir()
        name = f'HanQ-{version}-build{build}-arm64.dmg'
        dmg = output / name
        run('hdiutil', 'create', '-quiet', '-volname', f'한Q {version}', '-srcfolder', payload,
            '-fs', 'APFS', '-format', 'ULFO', dmg)
        run('hdiutil', 'verify', dmg)
        mount = stage / 'mount'; mount.mkdir()
        attached = False
        try:
            run('hdiutil', 'attach', '-readonly', '-nobrowse', '-mountpoint', mount, dmg)
            attached = True
            run('codesign', '--verify', '--deep', '--strict', mount / 'HanQ.app')
            if sha(mount / 'HanQ.app/Contents/MacOS/HanQ') != sha(app / 'Contents/MacOS/HanQ'):
                raise SystemExit('Mounted executable mismatch')
            if os.readlink(mount / 'Applications') != '/Applications':
                raise SystemExit('Invalid Applications link')
        finally:
            if attached:
                run('hdiutil', 'detach', mount)
        signature = run(sparkle / 'bin/sign_update', '--account', 'taek.in.hanq', '-p', dmg)
        run(sparkle / 'bin/sign_update', '--account', 'taek.in.hanq', '--verify', dmg, signature)
        digest = sha(dmg)
        (output / 'SHA256SUMS').write_text(f'{digest}  {name}\n')
        notes = (ROOT / 'CHANGELOG.md').read_text().split('\n## ', 2)[1]
        notes = notes.split('\n', 1)[1].strip()
        (output / 'release-notes.md').write_text(f'# 한Q {version} (빌드 {build})\n\n{notes}\n')
        rss = ET.Element('rss', {'version': '2.0'})
        channel = ET.SubElement(rss, 'channel')
        ET.SubElement(channel, 'title').text = '한Q 업데이트'
        ET.SubElement(channel, 'link').text = 'https://github.com/jungti1234/hanq'
        item = ET.SubElement(channel, 'item')
        ET.SubElement(item, 'title').text = f'한Q {version}'
        for field, value in [('version', build), ('shortVersionString', version),
                             ('minimumSystemVersion', info['LSMinimumSystemVersion']), ('hardwareRequirements', 'arm64')]:
            ET.SubElement(item, f'{{{SPARKLE_NS}}}{field}').text = value
        if '-beta.' in version:
            ET.SubElement(item, f'{{{SPARKLE_NS}}}channel').text = 'beta'
        ET.SubElement(item, 'enclosure', {'url': f'https://github.com/jungti1234/hanq/releases/download/v{version}/{name}',
                      f'{{{SPARKLE_NS}}}edSignature': signature, 'length': str(dmg.stat().st_size), 'type': 'application/octet-stream'})
        ET.indent(rss)
        ET.ElementTree(rss).write(output / 'appcast-candidate.xml', encoding='utf-8', xml_declaration=True)
        metadata = {'version': version, 'build': int(build), 'tag': f'v{version}',
                    'sourceCommit': run('git', 'rev-parse', 'HEAD'),
                    'workingTreeDirty': bool(run('git', 'status', '--porcelain')),
                    'sourceSHA256': identity['sourceSHA256'], 'dmg': name, 'sha256': digest,
                    'edSignature': signature, 'signing': 'ad-hoc', 'notarized': False,
                    'validation': ['app-signature', 'dmg-integrity', 'mounted-app-signature',
                                   'mounted-executable-match', 'applications-link', 'ed25519-signature']}
        (output / 'release-metadata.json').write_text(json.dumps(metadata, indent=2) + '\n')
        output.rename(destination)
        print(destination)
    finally:
        shutil.rmtree(stage)


def draft(folder):
    folder = folder.resolve()
    meta = json.loads((folder / 'release-metadata.json').read_text())
    if run('git', 'status', '--porcelain'):
        raise SystemExit('Commit the reviewed source and documents before creating a draft.')
    if meta['sourceSHA256'] != source_hashes():
        raise SystemExit('Packaged source does not match this checkout.')
    if sha(folder / meta['dmg']) != meta['sha256']:
        raise SystemExit('Release file has changed after verification.')
    sparkle = Path(run('bash', 'scripts/prepare-sparkle.sh'))
    config = json.loads((ROOT / 'updates/config.json').read_text())
    if run(sparkle / 'bin/generate_keys', '--account', 'taek.in.hanq', '-p') != config['sparklePublicKey']:
        raise SystemExit('Signing key does not match release configuration.')
    run(sparkle / 'bin/sign_update', '--account', 'taek.in.hanq', '--verify', folder / meta['dmg'], meta['edSignature'])
    if (folder / 'SHA256SUMS').read_text() != f"{meta['sha256']}  {meta['dmg']}\n":
        raise SystemExit('Checksum document does not match the verified DMG.')
    # Commit-only documentation changes do not require rebuilding the tested app.
    for name in meta['sourceSHA256']:
        if run('git', 'ls-files', '--error-unmatch', name) != name:
            raise SystemExit(f'Untracked build input: {name}')
    releases = [json.loads(line) for line in run('gh', 'api', '--paginate', 'repos/jungti1234/hanq/releases',
                '--jq', '.[] | {tag: .tag_name, draft: .draft, assets: [.assets[].name]}').splitlines() if line]
    for release in releases:
        if release['tag'] == meta['tag']:
            raise SystemExit('This tag already has a release; refusing to replace it.')
        if not release['draft']:
            builds = [int(n) for asset in release['assets'] for n in re.findall(r'-build(\d+)-', asset)]
            if not builds or max(builds) >= meta['build']:
                raise SystemExit('Cannot prove this build is newer than every public release.')
    if run('git', 'ls-remote', '--tags', 'origin', 'refs/tags/' + meta['tag']):
        raise SystemExit('Tag already exists; refusing to reuse it.')
    commit = run('git', 'rev-parse', 'HEAD')
    # Pin the draft to the exact reviewed commit, which must already exist remotely.
    run('gh', 'api', f'repos/jungti1234/hanq/commits/{commit}', '--jq', '.sha')
    meta['sourceCommit'] = commit; meta['workingTreeDirty'] = False
    (folder / 'release-metadata.json').write_text(json.dumps(meta, indent=2) + '\n')
    args = ['gh', 'release', 'create', meta['tag'], '--repo', 'jungti1234/hanq', '--target', commit,
            '--draft', '--title', f"한Q {meta['version']}", '--notes-file', str(folder / 'release-notes.md')]
    if '-beta.' in meta['version']:
        args.append('--prerelease')
    args += [str(folder / name) for name in [meta['dmg'], 'SHA256SUMS', 'release-metadata.json']]
    print(run(*args))


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest='command', required=True)
    sub.add_parser('prepare').add_argument('--app', type=Path, default=Path('build/candidate/HanQ.app'))
    sub.add_parser('draft').add_argument('folder', type=Path)
    args = parser.parse_args()
    if args.command == 'prepare': prepare(args.app)
    else: draft(args.folder)

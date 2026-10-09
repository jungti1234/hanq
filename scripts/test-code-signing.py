#!/usr/bin/env python3
"""Real signature/DR regression checks; no app launch or TCC changes."""
import importlib.util
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import tempfile

spec = importlib.util.spec_from_file_location('signing', Path(__file__).with_name('sign-app.py'))
signing = importlib.util.module_from_spec(spec)
spec.loader.exec_module(signing)
identity = os.environ.get('HANQ_SIGNING_IDENTITY')

with tempfile.TemporaryDirectory(prefix='hanq-signing-tests-') as directory:
    def fixture(name, version):
        app = Path(directory) / (name + '.app')
        (app / 'Contents/MacOS').mkdir(parents=True)
        (app / 'Contents/Resources').mkdir()
        shutil.copyfile('/usr/bin/true', app / 'Contents/MacOS/Probe')
        (app / 'Contents/MacOS/Probe').chmod(0o755)
        (app / 'Contents/Resources/content.txt').write_text(version)
        with (app / 'Contents/Info.plist').open('wb') as stream:
            plistlib.dump(dict(CFBundleIdentifier='taek.in.hanq.signing-tests',
                               CFBundleExecutable='Probe', CFBundlePackageType='APPL',
                               CFBundleVersion=version), stream)
        return app

    adhoc = fixture('Adhoc', '1')
    assert signing.sign(adhoc, '-')['mode'] == 'ad-hoc'
    try:
        signing.sign(adhoc, 'certificate-name')
        raise AssertionError('Accepted an ambiguous identity name')
    except ValueError:
        pass
    print('PASS: ad-hoc signature and ambiguous identity rejection')
    if not identity:
        print('SKIP: certificate checks require HANQ_SIGNING_IDENTITY')
    else:
        first, second = fixture('First', '1'), fixture('Second', '2')
        a, b = signing.sign(first, identity), signing.sign(second, identity)
        assert a['certificateSHA1'] == b['certificateSHA1'] == identity.upper()
        assert a['cdhash'] != b['cdhash']
        assert a['designatedRequirement'] == b['designatedRequirement']
        for app in (first, second):
            signing.run('/usr/bin/codesign', '--verify', '--strict', '-R', '=' + a['designatedRequirement'], app)
        try:
            signing.run('/usr/bin/codesign', '--verify', '-R', '=' + a['designatedRequirement'], adhoc)
            raise AssertionError('Certificate requirement accepted an ad-hoc app')
        except subprocess.CalledProcessError:
            pass
        try:
            signing.sign(first, '0' * 40)
            raise AssertionError('Missing certificate was accepted')
        except subprocess.CalledProcessError:
            assert signing.inspect(first) == a  # No silent ad-hoc replacement.
        (second / 'Contents/Resources/content.txt').write_text('tampered')
        try:
            signing.inspect(second)
            raise AssertionError('Modified resources were accepted')
        except subprocess.CalledProcessError:
            pass
        print('PASS: distinct CDHashes, stable DR, cross-build validation, ad-hoc rejection, missing identity, tamper rejection')

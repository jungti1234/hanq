#!/usr/bin/env python3
"""Sign with an explicit certificate, or ad-hoc; never fall back after failure."""
import argparse
import hashlib
import json
from pathlib import Path
import plistlib
import re
import subprocess
import tempfile


def run(*args):
    return subprocess.run([str(arg) for arg in args], check=True,
                          capture_output=True, text=True)


def inspect(app):
    app = Path(app).resolve()
    run('/usr/bin/codesign', '--verify', '--deep', '--strict', app)
    details = run('/usr/bin/codesign', '-d', '--verbose=4', app).stderr
    output = run('/usr/bin/codesign', '-d', '-r-', app)
    requirement = output.stdout + output.stderr
    requirement = next(line.split('=>', 1)[1].strip() for line in requirement.splitlines()
                       if 'designated =>' in line)
    fields = dict(line.split('=', 1) for line in details.splitlines() if '=' in line)
    result = {'mode': 'ad-hoc', 'identifier': fields['Identifier'],
              'cdhash': fields['CDHash'], 'designatedRequirement': requirement,
              'certificateSHA1': None}
    if fields.get('Signature') != 'adhoc':
        with tempfile.TemporaryDirectory(prefix='hanq-public-certificate-') as directory:
            prefix = Path(directory) / 'certificate'
            run('/usr/bin/codesign', '-d', '--extract-certificates=' + str(prefix), app)
            certificate = Path(str(prefix) + '0')
            result['certificateSHA1'] = hashlib.sha1(certificate.read_bytes()).hexdigest().upper()
            names = run('/usr/bin/openssl', 'x509', '-inform', 'DER', '-in', certificate,
                        '-noout', '-subject', '-issuer').stdout.splitlines()
            subject, issuer = [line.split('=', 1)[1].strip() for line in names]
            result['mode'] = 'self-signed' if subject == issuer else 'certificate-signed'
    return result


def sign(app, identity):
    app = Path(app).resolve()
    if identity != '-' and not re.fullmatch(r'[0-9a-fA-F]{40}', identity):
        raise ValueError('서명 인증서는 이름 대신 40자리 SHA-1 지문을 지정하세요.')
    with (app / 'Contents/Info.plist').open('rb') as stream:
        identifier = plistlib.load(stream)['CFBundleIdentifier']
    run('/usr/bin/codesign', '--force', '--sign', identity, '--timestamp=none', app)
    result = inspect(app)
    if result['identifier'] != identifier:
        raise ValueError('번들 ID와 서명 식별자가 다릅니다.')
    if identity != '-':
        if result['certificateSHA1'] != identity.upper() or 'cdhash' in result['designatedRequirement']:
            raise ValueError('요청한 인증서 또는 안정적인 서명 식별 조건과 다릅니다.')
    return result


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('app', type=Path)
    parser.add_argument('--identity', default='-')
    parser.add_argument('--inspect', action='store_true')
    args = parser.parse_args()
    try:
        print(json.dumps(inspect(args.app) if args.inspect else sign(args.app, args.identity), indent=2))
    except subprocess.CalledProcessError as error:
        parser.exit(1, error.stderr or str(error))
    except (OSError, ValueError, KeyError, StopIteration) as error:
        parser.exit(1, str(error) + '\n')

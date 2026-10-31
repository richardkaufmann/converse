#!/usr/bin/env python3
"""Use a private App Store Connect team key; never print keys or JWTs."""
import argparse
import base64
import json
from pathlib import Path
import plistlib
import subprocess
import tempfile
import time
import urllib.error
import urllib.request
import uuid


def load_config(path):
    config = json.loads(path.read_text())
    for field in ('keyID', 'issuerID', 'keyPath', 'teamID', 'appID'):
        if not isinstance(config.get(field), str) or not config[field].strip():
            raise ValueError(f'Missing configuration field: {field}')
    uuid.UUID(config['issuerID'])
    if not config['appID'].isdigit():
        raise ValueError('appID must be numeric')
    key = Path(config['keyPath']).expanduser().resolve(strict=True)
    if key.stat().st_mode & 0o077:
        raise ValueError('Private key permissions must be 0600 (chmod 600 the key file)')
    config['keyPath'] = str(key)
    return config


def verify(config):
    # Dependency needed only for this read-only API check, not for xcodebuild.
    from cryptography.hazmat.primitives import hashes, serialization
    from cryptography.hazmat.primitives.asymmetric import ec, utils

    def encode(value):
        return base64.urlsafe_b64encode(value).rstrip(b'=')

    now = int(time.time())
    header = {'alg': 'ES256', 'kid': config['keyID'], 'typ': 'JWT'}
    claims = {'iss': config['issuerID'], 'iat': now, 'exp': now + 300,
              'aud': 'appstoreconnect-v1'}
    message = b'.'.join(encode(json.dumps(v, separators=(',', ':')).encode())
                        for v in (header, claims))
    key = serialization.load_pem_private_key(Path(config['keyPath']).read_bytes(), None)
    r, s = utils.decode_dss_signature(key.sign(message, ec.ECDSA(hashes.SHA256())))
    token = (message + b'.' + encode(r.to_bytes(32, 'big') + s.to_bytes(32, 'big'))).decode()
    request = urllib.request.Request(
        'https://api.appstoreconnect.apple.com/v1/apps/' + config['appID'],
        headers={'Authorization': 'Bearer ' + token})
    with urllib.request.urlopen(request, timeout=30) as response:
        app = json.load(response)['data']
    print('API authentication verified:', app['attributes']['name'],
          app['attributes']['bundleId'], '(read-only; no upload)')


def distribute(config, archive, output, upload):
    archive = archive.resolve(strict=True)
    if not (archive / 'Info.plist').is_file():
        raise ValueError('Expected an existing .xcarchive directory')
    options = {'method': 'app-store-connect', 'destination': 'upload' if upload else 'export',
               'signingStyle': 'automatic', 'teamID': config['teamID'],
               'manageAppVersionAndBuildNumber': False,
               'testFlightInternalTestingOnly': True, 'uploadSymbols': True,
               'stripSwiftSymbols': True}
    with tempfile.TemporaryDirectory(prefix='converse-export-') as tmp:
        plist = Path(tmp) / 'ExportOptions.plist'
        plist.write_bytes(plistlib.dumps(options))
        subprocess.run(['xcodebuild', '-exportArchive', '-archivePath', str(archive),
                        '-exportOptionsPlist', str(plist), '-exportPath', str(output.resolve()),
                        '-allowProvisioningUpdates', '-authenticationKeyPath', config['keyPath'],
                        '-authenticationKeyID', config['keyID'],
                        '-authenticationKeyIssuerID', config['issuerID']], check=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--config', type=Path, default=Path.home() / '.config/converse/app-store-connect/config.json')
    commands = parser.add_subparsers(dest='command', required=True)
    commands.add_parser('verify', help='Read app metadata to verify authentication (requires cryptography)')
    for command in ('export', 'upload'):
        child = commands.add_parser(command, help='Sign locally' if command == 'export' else 'Sign and upload to TestFlight')
        child.add_argument('archive', type=Path)
        child.add_argument('output', type=Path)
    args = parser.parse_args()
    try:
        config = load_config(args.config)
        if args.command == 'verify':
            verify(config)
        else:
            distribute(config, args.archive, args.output, args.command == 'upload')
    except urllib.error.HTTPError as error:
        parser.exit(1, f'Apple API returned HTTP {error.code}; check key role, issuer, and app access.\n')
    except (ValueError, OSError, ImportError, KeyError, subprocess.CalledProcessError) as error:
        parser.exit(1, f'{type(error).__name__}: {error}\n')


if __name__ == '__main__':
    main()

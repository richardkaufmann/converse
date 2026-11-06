#!/usr/bin/env python3
"""Preserve a stopped TEST backup without leaving another launchable bundle."""
import argparse
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys
import tempfile
import zipfile

LSREGISTER = '/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister'


def require_stopped(app):
    executable = (app / 'Contents/MacOS/Converse').resolve()
    commands = subprocess.check_output(['ps', '-axo', 'comm='], text=True)
    if any(Path(line.strip()).resolve() == executable for line in commands.splitlines() if line.strip().endswith('/Contents/MacOS/Converse')):
        raise RuntimeError(f'Refusing to archive a running TEST app: {app}')


def archive(app, provider):
    app = Path(app).absolute()
    if app.is_symlink() or app.suffix != '.app':
        raise ValueError('Choose a real TEST backup bundle, not a symlink')
    with (app / 'Contents/Info.plist').open('rb') as stream:
        info = plistlib.load(stream)
    if info.get('CFBundleIdentifier') != 'local.richard.Converse.Test.' + provider:
        raise ValueError('Backup is not the selected provider TEST edition')
    require_stopped(app)
    archive_path = app.with_suffix('.app.zip')
    if archive_path.exists():
        raise FileExistsError(f'Archive already exists; backup retained: {archive_path}')
    with tempfile.TemporaryDirectory(prefix='.archive-test-', dir=app.parent) as temporary:
        candidate = Path(temporary) / 'backup.zip'
        subprocess.run(['/usr/bin/ditto', '-c', '-k', '--sequesterRsrc', '--keepParent', str(app), str(candidate)], check=True)
        with zipfile.ZipFile(candidate) as zipped:
            if zipped.testzip() is not None:
                raise RuntimeError('Backup archive failed its integrity check')
            prefix = app.name + '/'
            # Verify every regular file, including executable bytes, before removing the bundle.
            for source in app.rglob('*'):
                if source.is_file() and not source.is_symlink():
                    if zipped.read(prefix + source.relative_to(app).as_posix()) != source.read_bytes():
                        raise RuntimeError(f'Backup archive differs from {source}')
        require_stopped(app)
        # Publish without overwriting any backup, even if another process created it.
        os.link(candidate, archive_path)
        unregister = subprocess.run([LSREGISTER, '-u', str(app)], capture_output=True, text=True)
        if unregister.returncode:
            # Already-unregistered bundles can return -10814. Removing the verified
            # backup bundle still prevents launch; the installer registers its destination.
            print(f'Launch Services could not unregister {app}; retaining its ZIP and removing the launchable backup.', file=sys.stderr)
        require_stopped(app)
        shutil.rmtree(app)
    return archive_path


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('provider', choices=['Codex', 'Claude', 'Muse'])
    parser.add_argument('backup', type=Path)
    args = parser.parse_args()
    print(archive(args.backup, args.provider))

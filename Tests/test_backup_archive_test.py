import importlib.util
from pathlib import Path
import plistlib
import subprocess
import tempfile
import unittest
from unittest.mock import patch
import zipfile

spec = importlib.util.spec_from_file_location('backup', Path(__file__).resolve().parents[1] / 'scripts/archive-test-backup.py')
backup = importlib.util.module_from_spec(spec)
spec.loader.exec_module(backup)


class TestBackupArchive(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.app = Path(self.temporary.name) / 'Previous Codex Converse TEST.app'
        (self.app / 'Contents/MacOS').mkdir(parents=True)
        (self.app / 'Contents/MacOS/Converse').write_bytes(b'executable fixture')
        (self.app / 'Contents/Info.plist').write_bytes(plistlib.dumps({'CFBundleIdentifier': 'local.richard.Converse.Test.Codex'}))

    def test_archive_is_recoverable_and_old_bundle_is_unregistered(self):
        real_run = subprocess.run
        unregistered = []
        def run(command, **kwargs):
            if command[0] == backup.LSREGISTER:
                self.assertTrue(self.app.with_suffix('.app.zip').is_file())
                self.assertTrue(self.app.exists())
                unregistered.append(command)
                return subprocess.CompletedProcess(command, 0)
            return real_run(command, **kwargs)
        with patch.object(backup.subprocess, 'run', side_effect=run):
            archive = backup.archive(self.app, 'Codex')
        self.assertFalse(self.app.exists())
        self.assertEqual(unregistered, [[backup.LSREGISTER, '-u', str(self.app)]])
        restored = Path(self.temporary.name) / 'restored'
        subprocess.run(['/usr/bin/ditto', '-x', '-k', str(archive), str(restored)], check=True)
        self.assertEqual((restored / self.app.name / 'Contents/MacOS/Converse').read_bytes(), b'executable fixture')

    def test_running_backup_is_untouched(self):
        with patch.object(backup.subprocess, 'check_output', return_value=str(self.app / 'Contents/MacOS/Converse') + '\n'):
            with self.assertRaises(RuntimeError): backup.archive(self.app, 'Codex')
        self.assertTrue(self.app.exists())
        self.assertFalse(self.app.with_suffix('.app.zip').exists())

    def test_wrong_edition_is_untouched(self):
        with self.assertRaises(ValueError): backup.archive(self.app, 'Claude')
        self.assertTrue(self.app.exists())

    def test_unregistered_backup_still_becomes_archive(self):
        real_run = subprocess.run
        def run(command, **kwargs):
            if command[0] == backup.LSREGISTER: return subprocess.CompletedProcess(command, 1)
            return real_run(command, **kwargs)
        with patch.object(backup.subprocess, 'run', side_effect=run):
            archive = backup.archive(self.app, 'Codex')
        self.assertTrue(archive.exists())
        self.assertFalse(self.app.exists())

    def test_existing_archive_is_not_overwritten(self):
        archive = self.app.with_suffix('.app.zip')
        archive.write_bytes(b'previous archive')
        with self.assertRaises(FileExistsError): backup.archive(self.app, 'Codex')
        self.assertEqual(archive.read_bytes(), b'previous archive')
        self.assertTrue(self.app.exists())

    def test_failed_archive_keeps_bundle(self):
        real_run = subprocess.run
        def fail(command, **kwargs):
            if command[0] == '/usr/bin/ditto': raise subprocess.CalledProcessError(1, 'ditto')
            return real_run(command, **kwargs)
        with patch.object(backup.subprocess, 'run', side_effect=fail):
            with self.assertRaises(subprocess.CalledProcessError): backup.archive(self.app, 'Codex')
        self.assertTrue(self.app.exists())
        self.assertFalse(self.app.with_suffix('.app.zip').exists())

    def test_corrupt_archive_keeps_bundle(self):
        real_run = subprocess.run
        def corrupt(command, **kwargs):
            if command[0] != '/usr/bin/ditto': return real_run(command, **kwargs)
            with zipfile.ZipFile(command[-1], 'w') as zipped:
                zipped.writestr(self.app.name + '/Contents/MacOS/Converse', b'wrong data')
        with patch.object(backup.subprocess, 'run', side_effect=corrupt):
            with self.assertRaises((KeyError, RuntimeError)): backup.archive(self.app, 'Codex')
        self.assertTrue(self.app.exists())
        self.assertFalse(self.app.with_suffix('.app.zip').exists())


if __name__ == '__main__': unittest.main()

#!/usr/bin/env python3
"""Run install migration scripts only in temporary fixtures with mock OS services.

No installed files, actual processes, root authorization, HAL loading or audio services.
"""
import pathlib
import plistlib
import shlex
import shutil
import subprocess
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[2]


class MigrationTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='sonoferry-migration-test-')
        self.addCleanup(self.temp.cleanup)
        self.root = pathlib.Path(self.temp.name)
        self.app = self.root / 'Applications/SonoFerry.app'
        self.old = self.root / 'Applications/MacLDAC.app'
        self.driver = self.root / 'Library/Audio/Plug-Ins/HAL/SonoFerry.driver'
        self.old_driver = self.root / 'Library/Audio/Plug-Ins/HAL/MacLDAC.driver'
        self.bundle(self.app, 'local.SonoFerry')
        self.bundle(self.old, 'local.MacLDAC')
        self.bundle(self.driver, 'local.SonoFerry.LDACOutput', SonoFerryEngineCDHash='matched-hash')
        self.bundle(self.old_driver, 'local.MacLDAC.LDACOutput')
        self.lock = self.root / 'Library/Application Support/SonoFerry/ldac-route-owner.lock'
        self.lock.parent.mkdir(parents=True)
        self.lock.write_text('persistent-lock')
        self.old_lock = self.root / 'Library/Application Support/MacLDAC/ldac-route-owner.lock'
        self.old_lock.parent.mkdir(parents=True)
        self.old_lock.write_text('previous-product-lock')
        self.preferences = self.root / 'User/Library/Preferences/local.MacLDAC.plist'
        self.preferences.parent.mkdir(parents=True)
        self.preferences.write_text('persistent-settings')
        self.processes = self.root / 'processes'
        self.processes.write_text('/usr/bin/other-process\n')
        self.ps = self.command('ps', 'cat ' + shlex.quote(str(self.processes)) + '\n')
        self.plistbuddy = self.python_command('plistbuddy', '''import plistlib, sys
try:
    key = sys.argv[2].split(':', 1)[1]
    print(plistlib.loads(open(sys.argv[3], 'rb').read())[key])
except Exception:
    sys.exit(1)
''')
        self.codesign = self.python_command('codesign', '''import pathlib, sys
path = pathlib.Path(sys.argv[-1])
if not path.exists():
    sys.exit(1)
if '-d' in sys.argv:
    print('CDHash=matched-hash', file=sys.stderr)
''')
        self.stat = self.command('stat', '''case "$2" in
    '%u:%Lp') echo '0:755' ;;
    '%u:%Lp:%l') echo '0:644:1' ;;
    *) exit 1 ;;
esac
''')
        self.install = self.command('install', 'for item do destination="$item"; done\n/bin/mkdir -p -- "$destination"\n')
        self.chown = self.command('chown', 'exit 0\n')
        self.receipts = self.root / 'receipts.log'
        self.pkgutil = self.command('pkgutil', 'echo "$*" >> ' + shlex.quote(str(self.receipts)) + '\n')
        self.scripts = self.root / 'scripts'
        self.scripts.mkdir()
        commands = [('/bin/ps', self.ps), ('/usr/libexec/PlistBuddy', self.plistbuddy),
                    ('/usr/bin/codesign', self.codesign), ('/usr/bin/stat', self.stat),
                    ('/usr/bin/install', self.install), ('/usr/sbin/chown', self.chown), ('/usr/sbin/pkgutil', self.pkgutil)]
        for name in ['common.sh', 'preinstall', 'postinstall']:
            source = (ROOT / 'Packaging/Install' / name).read_text()
            source = source.replace('/Applications', str(self.root / 'Applications'))
            source = source.replace('/Library', str(self.root / 'Library'))
            for original, fixture in commands:
                source = source.replace(original, shlex.quote(str(fixture)))
            (self.scripts / name).write_text(source)

    def bundle(self, path, identifier, **values):
        (path / 'Contents').mkdir(parents=True, exist_ok=True)
        values['CFBundleIdentifier'] = identifier
        (path / 'Contents/Info.plist').write_bytes(plistlib.dumps(values))
        if path == self.app:
            (path / 'Contents/Helpers/SonoFerry Engine.app').mkdir(parents=True, exist_ok=True)

    def command(self, name, body):
        path = self.root / name
        path.write_text('#!/bin/sh\n' + body)
        path.chmod(0o755)
        return path

    def python_command(self, name, body):
        import sys
        return self.command(name, 'exec ' + shlex.quote(sys.executable) + ' - "$@" <<\'PY\'\n' + body + 'PY\n')

    def run_script(self, name, target='/'):
        return subprocess.run(['/bin/sh', str(self.scripts / name), 'package', 'location', target],
                              capture_output=True, text=True, timeout=8)

    def assert_preserved(self):
        self.assertTrue(self.app.exists())
        self.assertTrue(self.old.exists())
        self.assertTrue(self.old_driver.exists())
        self.assertTrue(self.driver.exists())
        self.assertEqual(self.lock.read_text(), 'persistent-lock')
        self.assertEqual(self.preferences.read_text(), 'persistent-settings')

    def test_preinstall_is_read_only(self):
        result = self.run_script('preinstall')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assert_preserved()

    def test_verified_upgrade_removes_legacy_app_driver_and_receipts(self):
        result = self.run_script('postinstall')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(self.old.exists())
        self.assertFalse(self.old_driver.exists())
        self.assertEqual(self.old_lock.read_text(), 'previous-product-lock')
        self.assertIn('--forget local.MacLDAC.package', self.receipts.read_text())
        self.assertTrue(self.app.exists())
        self.assertTrue(self.driver.exists())
        self.assertEqual(self.lock.read_text(), 'persistent-lock')
        self.assertEqual(self.preferences.read_text(), 'persistent-settings')
        self.assertIn('SonoFerry installed.', result.stdout)

    def test_fresh_install_and_repeat_postinstall(self):
        shutil.rmtree(self.old)
        shutil.rmtree(self.old_driver)
        for _ in range(2):
            result = self.run_script('postinstall')
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertTrue(self.app.exists())
            self.assertTrue(self.driver.exists())

    def test_signature_failure_never_deletes_legacy(self):
        self.command('codesign', 'exit 1\n')
        self.assertNotEqual(self.run_script('postinstall').returncode, 0)
        self.assert_preserved()

    def test_hash_mismatch_never_deletes_legacy(self):
        self.bundle(self.driver, 'local.SonoFerry.LDACOutput', SonoFerryEngineCDHash='different-hash')
        self.assertNotEqual(self.run_script('postinstall').returncode, 0)
        self.assert_preserved()

    def test_missing_new_app_never_deletes_legacy(self):
        shutil.rmtree(self.app)
        self.assertNotEqual(self.run_script('postinstall').returncode, 0)
        self.assertTrue(self.old.exists())
        self.assertTrue(self.old_driver.exists())
        self.assertTrue(self.driver.exists())

    def test_unrelated_targets_block_pre_and_post(self):
        for path in [self.app, self.old, self.driver, self.old_driver]:
            original = (path / 'Contents/Info.plist').read_bytes()
            self.bundle(path, 'com.example.unrelated')
            for stage in ['preinstall', 'postinstall']:
                self.assertNotEqual(self.run_script(stage).returncode, 0)
                self.assert_preserved()
            (path / 'Contents/Info.plist').write_bytes(original)

    def test_legacy_symlink_is_never_followed(self):
        target = self.root / 'Other.app'
        self.old.rename(target)
        self.old.symlink_to(target, target_is_directory=True)
        for stage in ['preinstall', 'postinstall']:
            self.assertNotEqual(self.run_script(stage).returncode, 0)
            self.assert_preserved()
            self.assertTrue(target.exists())

    def test_legacy_info_symlink_is_refused(self):
        info = self.old / 'Contents/Info.plist'
        target = self.root / 'outside-info.plist'
        info.rename(target)
        info.symlink_to(target)
        self.assertNotEqual(self.run_script('postinstall').returncode, 0)
        self.assert_preserved()
        self.assertTrue(target.exists())

    def test_invalid_legacy_plist_is_refused(self):
        (self.old / 'Contents/Info.plist').write_text('invalid')
        self.assertNotEqual(self.run_script('postinstall').returncode, 0)
        self.assert_preserved()

    def test_linked_applications_directory_is_refused(self):
        parent = self.app.parent
        target = self.root / 'Outside'
        parent.rename(target)
        parent.symlink_to(target, target_is_directory=True)
        self.assertNotEqual(self.run_script('postinstall').returncode, 0)
        self.assert_preserved()

    def test_running_new_old_engine_and_helpers_block_install(self):
        for process in ['SonoFerry', 'MacLDAC', 'MacLDACEngine', 'MacLDACAudio', 'SonoFerryEngine', 'SonoFerryAudio',
                        '/Applications/SonoFerry.app/Contents/Helpers/MediaTransport',
                        '/Applications/MacLDAC.app/Contents/Helpers/MediaTransport']:
            self.processes.write_text(process + '\n')
            for stage in ['preinstall', 'postinstall']:
                self.assertNotEqual(self.run_script(stage).returncode, 0)
                self.assert_preserved()

    def test_process_query_failure_blocks_install(self):
        self.command('ps', 'exit 1\n')
        for stage in ['preinstall', 'postinstall']:
            self.assertNotEqual(self.run_script(stage).returncode, 0)
            self.assert_preserved()

    def test_late_process_blocks_legacy_cleanup(self):
        marker = shlex.quote(str(self.root / 'queried'))
        self.command('ps', 'if [ -e ' + marker + ' ]; then echo SonoFerry; else touch ' + marker + '; fi\n')
        self.assertNotEqual(self.run_script('postinstall').returncode, 0)
        self.assert_preserved()

    def test_legacy_delete_failure_reports_failure(self):
        fail_rm = self.command('rm-fails', 'exit 1\n')
        post = self.scripts / 'postinstall'
        post.write_text(post.read_text().replace('/bin/rm', shlex.quote(str(fail_rm))))
        result = self.run_script('postinstall')
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn('SonoFerry installed.', result.stdout)
        self.assert_preserved()

    def test_preinstall_accepts_old_identity_but_postinstall_requires_new(self):
        self.bundle(self.app, 'local.MacLDAC')
        self.assertEqual(self.run_script('preinstall').returncode, 0)
        self.assertNotEqual(self.run_script('postinstall').returncode, 0)
        self.assert_preserved()

    def test_legacy_driver_symlink_is_refused(self):
        target = self.root / 'Unrelated.driver'
        self.old_driver.rename(target)
        self.old_driver.symlink_to(target, target_is_directory=True)
        self.assertNotEqual(self.run_script('postinstall').returncode, 0)
        self.assertTrue(target.exists())
        self.assert_preserved()

    def test_legacy_driver_delete_failure_is_reported(self):
        rm = self.command('rm-driver-fails', 'case "$*" in *MacLDAC.driver*) exit 1;; esac\nexec /bin/rm "$@"\n')
        post = self.scripts / 'postinstall'
        post.write_text(post.read_text().replace('/bin/rm', shlex.quote(str(rm))))
        result = self.run_script('postinstall')
        self.assertNotEqual(result.returncode, 0)
        self.assertTrue(self.old_driver.exists())
        self.assertTrue(self.app.exists())
        self.assertTrue(self.driver.exists())
        self.assertNotIn('SonoFerry installed.', result.stdout)

    def test_receipt_failure_is_reported(self):
        self.command('pkgutil', '[ "$1" != --forget ]\n')
        result = self.run_script('postinstall')
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn('SonoFerry installed.', result.stdout)
        self.assertTrue(self.app.exists())
        self.assertTrue(self.driver.exists())

    def test_other_installation_volume_is_refused(self):
        self.assertNotEqual(self.run_script('preinstall', '/Volumes/Other').returncode, 0)
        self.assert_preserved()


if __name__ == '__main__':
    unittest.main(verbosity=2)

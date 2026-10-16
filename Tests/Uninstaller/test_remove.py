#!/usr/bin/env python3
"""Exercise the real removal script against temporary fixtures and mock OS commands.

No root, installed paths, process control, audio service or real package receipts.
The production script has no fixture-root or command-override switches.
"""
import os
import pathlib
import plistlib
import shlex
import subprocess
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[2]
SOURCE = (ROOT / 'Packaging/Uninstall/remove.sh').read_text()


class RemovalTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='sonoferry-removal-test-')
        self.addCleanup(self.temp.cleanup)
        self.root = pathlib.Path(self.temp.name)
        self.app = self.root / 'Applications/SonoFerry.app'
        self.driver = self.root / 'Library/Audio/Plug-Ins/HAL/SonoFerry.driver'
        self.bundle(self.app, 'local.SonoFerry')
        self.bundle(self.driver, 'local.SonoFerry.LDACOutput')
        self.kept = self.root / 'Library/Application Support/SonoFerry/ldac-route-owner.lock'
        self.kept.parent.mkdir(parents=True)
        self.kept.write_text('retain lock')
        self.preferences = self.root / 'user/Library/Preferences/local.SonoFerry.plist'
        self.preferences.parent.mkdir(parents=True)
        self.preferences.write_text('retain preferences')
        self.ps = self.command('ps', "printf '%s\\n' /usr/bin/other-process\n")
        self.uid = self.command('id', 'echo 0\n')
        self.receipts = self.root / 'receipts.log'
        self.pkgutil = self.command('pkgutil', 'echo "$*" >> ' + shlex.quote(str(self.receipts)) + '\n')
        script = SOURCE.replace('/Applications', str(self.root / 'Applications'))
        script = script.replace('/Library', str(self.root / 'Library'))
        for original, fixture in [('/bin/ps', self.ps), ('/usr/bin/id', self.uid), ('/usr/sbin/pkgutil', self.pkgutil)]:
            script = script.replace(original, shlex.quote(str(fixture)))
        self.script = self.root / 'remove.sh'
        self.script.write_text(script)

    def bundle(self, path, identifier):
        (path / 'Contents').mkdir(parents=True, exist_ok=True)
        (path / 'Contents/Info.plist').write_bytes(plistlib.dumps({'CFBundleIdentifier': identifier}))

    def command(self, name, body):
        path = self.root / name
        path.write_text('#!/bin/sh\n' + body)
        path.chmod(0o755)
        return path

    def run_script(self, *args):
        return subprocess.run(['/bin/sh', str(self.script), *args], capture_output=True, text=True, timeout=8)

    def assert_intact(self):
        self.assertTrue(self.app.exists())
        self.assertTrue(self.driver.exists())
        self.assertFalse(self.receipts.exists())

    def test_check_only_never_removes_or_forgets(self):
        self.command('id', 'exit 99\n')  # check-only must not require root
        result = self.run_script('--check-only')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('SONOFERRY_UNINSTALL_READY', result.stdout)
        self.assert_intact()

    def test_removes_both_but_retains_data_and_lock(self):
        result = self.run_script()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(self.app.exists())
        self.assertFalse(self.driver.exists())
        self.assertEqual(self.kept.read_text(), 'retain lock')
        self.assertEqual(self.preferences.read_text(), 'retain preferences')
        self.assertIn('--forget local.SonoFerry.package', self.receipts.read_text())
        self.assertIn('--forget local.SonoFerry.uninstall', self.receipts.read_text())

    def test_absent_targets_are_idempotent(self):
        self.assertEqual(self.run_script().returncode, 0)
        self.assertEqual(self.run_script().returncode, 0)

    def test_unrelated_app_blocks_driver_removal(self):
        self.bundle(self.app, 'com.example.other')
        self.assertNotEqual(self.run_script().returncode, 0)
        self.assert_intact()

    def test_unrelated_driver_blocks_app_removal(self):
        self.bundle(self.driver, 'com.example.other')
        self.assertNotEqual(self.run_script().returncode, 0)
        self.assert_intact()

    def test_malformed_plist_blocks_removal(self):
        (self.driver / 'Contents/Info.plist').write_text('not a plist')
        self.assertNotEqual(self.run_script().returncode, 0)
        self.assert_intact()

    def test_bundle_symlink_is_refused(self):
        outside = self.root / 'Unrelated.app'
        self.app.rename(outside)
        self.app.symlink_to(outside, target_is_directory=True)
        self.assertNotEqual(self.run_script().returncode, 0)
        self.assert_intact()
        self.assertTrue((outside / 'Contents/Info.plist').exists())

    def test_parent_symlink_is_refused(self):
        parent = self.driver.parent
        replacement = parent.with_name('HAL-original')
        parent.rename(replacement)
        parent.symlink_to(replacement, target_is_directory=True)
        self.assertNotEqual(self.run_script().returncode, 0)
        self.assert_intact()

    def test_info_symlink_is_refused(self):
        info = self.app / 'Contents/Info.plist'
        actual = self.root / 'info.plist'
        info.rename(actual)
        info.symlink_to(actual)
        self.assertNotEqual(self.run_script().returncode, 0)
        self.assert_intact()

    def test_running_app_engine_or_orphan_helper_is_refused(self):
        for process in ['SonoFerry', '/Applications/SonoFerry.app/Contents/MacOS/SonoFerry',
                        'SonoFerry', '/Applications/SonoFerry.app/Contents/MacOS/SonoFerry',
                        'SonoFerryEngine', '/tmp/SonoFerry.app/Contents/Helpers/MediaTransport',
                        '/tmp/SonoFerry.app/Contents/Helpers/MediaTransport']:
            with self.subTest(process=process):
                self.command('ps', 'echo ' + shlex.quote(process) + '\n')
                self.assertNotEqual(self.run_script().returncode, 0)
                self.assert_intact()

    def test_process_query_failure_is_refused(self):
        self.command('ps', 'exit 1\n')
        self.assertNotEqual(self.run_script().returncode, 0)
        self.assert_intact()

    def test_process_started_after_first_check_is_refused(self):
        marker = shlex.quote(str(self.root / 'queried'))
        self.command('ps', 'if [ -e ' + marker + ' ]; then echo SonoFerryEngine; else touch ' + marker + '; fi\n')
        self.assertNotEqual(self.run_script().returncode, 0)
        self.assert_intact()

    def test_non_root_is_refused(self):
        self.command('id', 'echo 501\n')
        self.assertNotEqual(self.run_script().returncode, 0)
        self.assert_intact()

    def test_delete_failure_never_claims_success(self):
        rm = self.command('rm-fails', 'exit 1\n')
        self.script.write_text(self.script.read_text().replace('/bin/rm', shlex.quote(str(rm))))
        result = self.run_script()
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn('SONOFERRY_UNINSTALL_COMPLETE', result.stdout)
        self.assert_intact()

    def test_receipt_failure_reports_partial_completion(self):
        self.command('pkgutil', '[ "$1" != --forget ]\n')
        result = self.run_script()
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn('SONOFERRY_UNINSTALL_COMPLETE', result.stdout)
        self.assertIn('应用和驱动已移除', result.stderr)

    def test_invalid_argument_is_refused(self):
        self.assertNotEqual(self.run_script('--unexpected').returncode, 0)
        self.assert_intact()


if __name__ == '__main__':
    unittest.main(verbosity=2)

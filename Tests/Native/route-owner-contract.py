#!/usr/bin/env python3
"""Replay the actual route-owner function against installer-created temporary paths.

Root ownership is simulated only in metadata reads. Real read-only open, symlink,
hard-link, permission-mode and flock checks run against fixtures, never /Library.
"""
import pathlib
import re
import shutil
import subprocess
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[2]
SOURCE = (ROOT / 'Sources/Engine/NativeOutput.swift').read_text()
BEGIN = SOURCE.index('    private static func acquireRouteOwner() throws {')
END = SOURCE.index('\n    private func setLease', BEGIN)
FUNCTION = SOURCE[BEGIN:END].replace('private static func acquireRouteOwner', 'static func acquireRouteOwner')
DIRECTORY = re.search(r'let directory = "([^\"]+)"', FUNCTION).group(1)
SUPPORT = {
    name: re.search(r"support='([^']+)'", (ROOT / 'Packaging/Install' / name).read_text()).group(1)
    for name in ['preinstall', 'postinstall']
}
assert DIRECTORY.startswith('/Library/Application Support/')
FUNCTION = FUNCTION.replace('let directory = "' + DIRECTORY + '"', 'let directory = fixtureRoot + "' + DIRECTORY + '"')


class RouteOwnerContractTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.build = tempfile.TemporaryDirectory(prefix='route-owner-replay-', dir=ROOT / '.build')
        cls.addClassCleanup(cls.build.cleanup)
        folder = pathlib.Path(cls.build.name)
        swift = folder / 'main.swift'
        swift.write_text('''import Foundation
import Darwin
final class Replay {
    static var fixtureRoot = ""
    static var routeOwner: FileHandle?
    static var emulateRootOwnership = true
    static func lstat(_ path: String, _ metadata: UnsafeMutablePointer<stat>) -> Int32 {
        let result = Darwin.lstat(path, metadata)
        if result == 0 && emulateRootOwnership { metadata.pointee.st_uid = 0 }
        return result
    }
    static func fstat(_ descriptor: Int32, _ metadata: UnsafeMutablePointer<stat>) -> Int32 {
        let result = Darwin.fstat(descriptor, metadata)
        if result == 0 && emulateRootOwnership { metadata.pointee.st_uid = 0 }
        return result
    }
''' + FUNCTION + '''
}
Replay.fixtureRoot = CommandLine.arguments[1]
let installedDirectory = Replay.fixtureRoot + CommandLine.arguments[2]
let mode = CommandLine.arguments[3]
Replay.emulateRootOwnership = mode != "untrusted-owner"
var competing: FileHandle?
if mode == "busy" {
    let descriptor = Darwin.open(installedDirectory + "/ldac-route-owner.lock", O_RDONLY)
    guard descriptor >= 0, flock(descriptor, LOCK_EX | LOCK_NB) == 0 else { exit(2) }
    competing = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
}
do {
    try Replay.acquireRouteOwner()
    print("ACQUIRED")
} catch let error as POSIXError {
    print("POSIX_ERROR=\\(error.code.rawValue)")
    exit(1)
} catch {
    print("UNEXPECTED_ERROR=\\(error)")
    exit(2)
}
''')
        cls.binary = folder / 'replay'
        subprocess.run(['xcrun', 'swiftc', '-target', 'arm64-apple-macos26.0',
                        '-module-cache-path', str(ROOT / '.build/route-owner-module-cache'),
                        str(swift), '-o', str(cls.binary)], check=True, timeout=120)

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='route-owner-fixture-')
        self.addCleanup(self.temp.cleanup)
        self.root = pathlib.Path(self.temp.name)
        self.directory = self.root / SUPPORT['postinstall'].lstrip('/')
        self.directory.mkdir(parents=True, mode=0o755)
        self.directory.chmod(0o755)
        self.lock = self.directory / 'ldac-route-owner.lock'
        self.lock.write_bytes(b'original-lock')
        self.lock.chmod(0o644)

    def replay(self, mode='normal'):
        return subprocess.run([str(self.binary), str(self.root), SUPPORT['postinstall'], mode],
                              capture_output=True, text=True, timeout=8)

    def test_installer_created_lock_can_be_acquired(self):
        original = self.lock.stat().st_ino
        result = self.replay()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn('ACQUIRED', result.stdout)
        self.assertEqual(self.lock.read_bytes(), b'original-lock')
        self.assertEqual(self.lock.stat().st_ino, original)

    def test_engine_preinstall_postinstall_use_same_directory(self):
        self.assertEqual(DIRECTORY, SUPPORT['preinstall'])
        self.assertEqual(DIRECTORY, SUPPORT['postinstall'])

    def test_missing_directory_is_refused(self):
        shutil.rmtree(self.directory)
        self.assertNotEqual(self.replay().returncode, 0)

    def test_untrusted_owner_is_refused(self):
        self.assertNotEqual(self.replay('untrusted-owner').returncode, 0)

    def test_writable_directory_is_refused(self):
        self.directory.chmod(0o777)
        self.assertNotEqual(self.replay().returncode, 0)

    def test_directory_symlink_is_refused(self):
        target = self.directory.with_name('external')
        self.directory.rename(target)
        self.directory.symlink_to(target, target_is_directory=True)
        self.assertNotEqual(self.replay().returncode, 0)
        self.assertEqual((target / self.lock.name).read_bytes(), b'original-lock')

    def test_lock_symlink_is_refused(self):
        target = self.directory / 'external-lock'
        self.lock.rename(target)
        self.lock.symlink_to(target)
        self.assertNotEqual(self.replay().returncode, 0)
        self.assertEqual(target.read_bytes(), b'original-lock')

    def test_hard_linked_lock_is_refused(self):
        import os
        os.link(self.lock, self.directory / 'another-link')
        self.assertNotEqual(self.replay().returncode, 0)

    def test_writable_lock_is_refused(self):
        self.lock.chmod(0o666)
        self.assertNotEqual(self.replay().returncode, 0)

    def test_competing_route_owner_is_refused_without_waiting(self):
        result = self.replay('busy')
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn('POSIX_ERROR=35', result.stdout)


if __name__ == '__main__':
    unittest.main(verbosity=2)

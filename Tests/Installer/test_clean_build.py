#!/usr/bin/env python3
"""Exercise bundle publication in a temporary tree; no compiler or installed app."""
import pathlib
import sys
import tempfile
import unittest
from unittest.mock import patch

ROOT = pathlib.Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'scripts'))
import build


class CleanBuildTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='sonoferry-build-test-')
        self.addCleanup(self.temp.cleanup)
        self.root = pathlib.Path(self.temp.name)
        self.app = self.root / 'dist/SonoFerry.app'
        self.app.mkdir(parents=True)
        (self.app / 'removed-resource').write_text('previous bundle')
        self.settings = patch.multiple(build, ROOT=self.root, BUILD=self.root / '.build/native',
                                       DIST=self.root / 'dist', APP=self.app)
        self.settings.start()
        self.addCleanup(self.settings.stop)

    @staticmethod
    def compile_fixture(app):
        app.mkdir()
        (app / 'current-resource').write_text('verified replacement')

    def test_success_publishes_clean_bundle_and_preserves_previous(self):
        with patch.object(build, 'build_app', self.compile_fixture):
            build.main()
        self.assertEqual([p.name for p in self.app.iterdir()], ['current-resource'])
        previous = list((self.root / '.build').glob('previous-*/SonoFerry.app/removed-resource'))
        self.assertEqual(len(previous), 1)
        self.assertEqual(previous[0].read_text(), 'previous bundle')

    def test_compile_or_signature_failure_preserves_delivery(self):
        def failure(app):
            self.compile_fixture(app)
            raise RuntimeError('compiler or signature verification failed')
        with patch.object(build, 'build_app', failure), self.assertRaises(RuntimeError):
            build.main()
        self.assertEqual([p.name for p in self.app.iterdir()], ['removed-resource'])
        self.assertEqual(list((self.root / '.build').glob('sonoferry-build-*')), [])

    def test_publication_failure_restores_previous_bundle(self):
        rename = pathlib.Path.rename
        def failing_rename(path, target):
            if path.parent.name.startswith('sonoferry-build-'):
                raise OSError('publication failure')
            return rename(path, target)
        with patch.object(build, 'build_app', self.compile_fixture), patch.object(pathlib.Path, 'rename', failing_rename), self.assertRaises(OSError):
            build.main()
        self.assertEqual([p.name for p in self.app.iterdir()], ['removed-resource'])


if __name__ == '__main__':
    unittest.main(verbosity=2)

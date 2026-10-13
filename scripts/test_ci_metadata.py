import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


class CiMetadataTests(unittest.TestCase):
    def run_metadata(self, event, reference_type, tag, prefix='v'):
        with tempfile.TemporaryDirectory() as temporary:
            manifest = Path(temporary) / 'pubspec.yaml'
            manifest.write_text('version: 9.8.7+123\n', encoding='utf-8')
            output = Path(temporary) / 'output'
            environment = os.environ | {
                'GITHUB_EVENT_NAME': event, 'GITHUB_REF_TYPE': reference_type,
                'GITHUB_REF_NAME': tag, 'GITHUB_OUTPUT': str(output), 'PYTHONUTF8': '1',
            }
            result = subprocess.run(
                [sys.executable, str(Path(__file__).with_name('ci_metadata.py')),
                 '--manifest', str(manifest), '--prefix', prefix],
                env=environment, capture_output=True, text=True, encoding='utf-8',
            )
            values = dict(line.split('=', 1) for line in output.read_text(encoding='utf-8').splitlines()) if output.exists() else {}
            return result, values

    def test_regular_commits_and_manual_runs_never_release(self):
        for event, reference_type, tag in [
            ('push', 'branch', 'main'),
            ('push', 'branch', 'v9.8.7'),
            ('pull_request', 'branch', 'main'),
            ('workflow_dispatch', 'tag', 'v9.8.7'),
        ]:
            with self.subTest(event=event, reference_type=reference_type):
                result, values = self.run_metadata(event, reference_type, tag)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(values['release'], 'false')

    def test_matching_formal_tag_releases(self):
        result, values = self.run_metadata('push', 'tag', 'v9.8.7')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(values, {'release': 'true', 'version': '9.8.7', 'package_version': '9.8.7+123'})

    def test_mismatched_formal_tag_stops_build(self):
        result, values = self.run_metadata('push', 'tag', 'v9.8.6')
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(values, {})

    def test_prerelease_tag_only_builds_test_packages(self):
        result, values = self.run_metadata('push', 'tag', 'v9.8.7-rc.1')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(values['release'], 'false')

    def test_compatibility_release_uses_its_own_tag_prefix(self):
        result, values = self.run_metadata('push', 'tag', 'android6-9.8.7', 'android6-')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(values['release'], 'true')
        result, values = self.run_metadata('push', 'tag', 'v9.8.7', 'android6-')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(values['release'], 'false')


if __name__ == '__main__':
    unittest.main()

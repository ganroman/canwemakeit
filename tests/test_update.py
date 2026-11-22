"""Exercise deployment decisions without contacting GitHub or changing real containers."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
NEW = "a" * 40
OLD = "b" * 40

STUB = r'''
import json, os, pathlib, sys
name = pathlib.Path(sys.argv[0]).name
args = sys.argv[1:]
with open(os.environ['CALL_LOG'], 'a') as log:
    log.write(json.dumps([name, *args]) + '\n')
case = os.environ['CASE']
new, old = 'a' * 40, 'b' * 40
if name == 'curl':
    if case == 'network_failure':
        sys.exit(22)
    print(json.dumps({'workflow_runs': [{
        'status': 'in_progress' if case == 'pending' else 'completed',
        'conclusion': 'failure' if case == 'failed_ci' else 'success',
        'head_sha': new,
    }]}))
elif name == 'git':
    if args[0] == 'status' and case == 'dirty':
        print(' M public/index.html')
    elif args[:2] == ['rev-parse', 'FETCH_HEAD']:
        print(old if case == 'superseded' else new)
    elif args[:2] == ['rev-parse', 'HEAD']:
        print(old)
elif name == 'docker':
    if args[:2] == ['image', 'inspect']:
        print('sha256:previous-image')
    if args[:2] == ['compose', 'up'] and case == 'rollout_failure':
        marker = pathlib.Path(os.environ['FAIL_MARKER'])
        if not marker.exists():
            marker.touch()
            sys.exit(1)
    if args[:2] == ['compose', 'build'] and case == 'build_failure':
        sys.exit(1)
'''


class UpdateTest(unittest.TestCase):
    def exercise(self, case):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / 'deploy').mkdir()
            shutil.copy(ROOT / 'deploy/update.sh', root / 'deploy/update.sh')
            (root / 'deploy/check-site.sh').write_text('exit 0\n')
            binaries = root / 'bin'
            binaries.mkdir()
            for name in ('curl', 'git', 'docker'):
                executable = binaries / name
                executable.write_text(f'#!{sys.executable}\n' + STUB)
                executable.chmod(0o755)
            if case == 'already_deployed':
                (root / '.deploy').mkdir()
                (root / '.deploy/deployed-sha').write_text(NEW + '\n')
            log = root / 'calls.jsonl'
            env = dict(os.environ, CASE=case, CALL_LOG=str(log),
                       FAIL_MARKER=str(root / 'failed-once'),
                       PATH=str(binaries) + os.pathsep + os.environ['PATH'])
            result = subprocess.run(['/bin/bash', str(root / 'deploy/update.sh')],
                                    env=env, text=True, capture_output=True)
            calls = [json.loads(line) for line in log.read_text().splitlines()]
            marker = root / '.deploy/deployed-sha'
            deployed = marker.read_text().strip() if marker.exists() else None
            return result, calls, deployed

    def test_unapproved_or_unchanged_revisions_do_not_touch_containers(self):
        for case in ('pending', 'failed_ci', 'superseded', 'already_deployed'):
            with self.subTest(case=case):
                result, calls, deployed = self.exercise(case)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertFalse(any(call[0] == 'docker' for call in calls))
                self.assertEqual(deployed, NEW if case == 'already_deployed' else None)

    def test_dirty_checkout_or_network_failure_stops_deployment(self):
        for case in ('dirty', 'network_failure'):
            with self.subTest(case=case):
                result, calls, deployed = self.exercise(case)
                self.assertNotEqual(result.returncode, 0)
                self.assertFalse(any(call[0] == 'docker' for call in calls))
                self.assertIsNone(deployed)

    def test_success_records_exact_verified_commit(self):
        result, calls, deployed = self.exercise('success')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(deployed, NEW)
        self.assertIn(['git', 'checkout', '--detach', NEW], calls)
        self.assertTrue(any(call[:3] == ['docker', 'compose', 'up'] for call in calls))

    def test_failure_restores_previous_checkout_and_image(self):
        for case in ('build_failure', 'rollout_failure'):
            with self.subTest(case=case):
                result, calls, deployed = self.exercise(case)
                self.assertNotEqual(result.returncode, 0)
                self.assertIsNone(deployed)
                self.assertIn(['git', 'checkout', '--detach', OLD], calls)
                self.assertIn(['docker', 'image', 'tag', 'sha256:previous-image',
                               'canwemakeit-homepage:local'], calls)
                self.assertTrue(any(call[:3] == ['docker', 'compose', 'up'] for call in calls))


if __name__ == '__main__':
    unittest.main()

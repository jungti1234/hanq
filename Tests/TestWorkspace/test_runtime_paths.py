"""Guard persistent GUI fixtures against protected directories and symlinks."""
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
import runpy
from unittest import mock

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'scripts'))
from test_workspace import temporary_root


class WorkspaceTests(unittest.TestCase):
    def test_accepts_absolute_temporary_descendants(self):
        self.assertEqual(temporary_root('/tmp/hanq-test with spaces'),
                         Path('/private/tmp/hanq-test with spaces'))

    def test_rejects_non_temporary_roots(self):
        for path in ('relative', '/private/tmp', '/', str(ROOT),
                     '/Users/example/Documents/test', '/Users/example/Desktop/test',
                     '/Users/example/Downloads/test'):
            with self.subTest(path=path), self.assertRaises(ValueError):
                temporary_root(path)

    def test_resolves_symlink_before_accepting(self):
        with tempfile.TemporaryDirectory(dir='/private/tmp') as directory:
            link = Path(directory) / 'protected'
            link.symlink_to(ROOT)
            with self.assertRaises(ValueError):
                temporary_root(link / 'fixture')

    def test_fixture_runs_with_temporary_working_directory(self):
        script = '''source scripts/test-workspace.sh
stage=$(hanq_test_stage workspace-regression)
trap 'rm -rf "$stage"' EXIT
hanq_test_run python3 -c 'from pathlib import Path; import sys; p=Path.cwd(); assert Path("/private/tmp") in p.parents; Path("result").write_text("ok"); sys.exit(7)'
status=$?
[[ $status == 7 && $(cat "$stage/result") == ok ]]
'''
        subprocess.run(['bash', '-c', script], cwd=ROOT, check=True)

    def test_launchservices_trace_is_exported_after_stop(self):
        # Exercise the actual supervisor; OS launch/process calls are isolated.
        with tempfile.TemporaryDirectory(dir='/private/tmp') as directory:
            output = Path(directory) / 'export'
            app = Path(directory) / 'HanQ.app'
            executable = str(app / 'Contents/MacOS/HanQ')
            probe_count = 0
            trace = None

            class LibProc:
                def proc_pidpath(self, pid, buffer, size):
                    buffer.value = executable.encode()
                    return len(buffer.value)

            def command(args, **kwargs):
                nonlocal probe_count, trace
                text = ''
                if args[0] == 'pgrep':
                    probe_count += 1
                    text = '' if probe_count == 1 else '12345\n'
                elif args[0] == 'open':
                    trace = Path(args[-1])
                    self.assertEqual(trace.parent.parent, Path('/private/tmp'))
                    self.assertNotEqual(trace.parent, output)
                    trace.write_text('fixture trace\n')
                elif args[-1] == 'lstart=':
                    text = 'fixture-start'
                return subprocess.CompletedProcess(args, 0, text, '')

            argv = ['run-app-input-diagnostic.py', '--seconds', '0.001',
                    '--output', str(output), str(app)]
            with mock.patch.object(sys, 'argv', argv), \
                 mock.patch('ctypes.CDLL', return_value=LibProc()), \
                 mock.patch('subprocess.run', side_effect=command), \
                 mock.patch('os.kill') as kill:
                runpy.run_path(str(ROOT / 'scripts/run-app-input-diagnostic.py'), run_name='__main__')
            kill.assert_called_once()
            self.assertEqual((output / 'trace.log').read_text(), 'fixture trace\n')
            self.assertFalse(trace.exists())


if __name__ == '__main__':
    unittest.main()

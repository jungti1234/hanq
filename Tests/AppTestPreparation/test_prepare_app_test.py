#!/usr/bin/env python3
"""Exercise fail-closed preparation without stopping apps or changing real TCC."""
import contextlib
import copy
import importlib.util
import io
import json
import pathlib
import plistlib
import shutil
import subprocess
import tempfile
import unittest
from unittest import mock

ROOT = pathlib.Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('preflight', ROOT / 'scripts/prepare-app-test.py')
preflight = importlib.util.module_from_spec(spec)
spec.loader.exec_module(preflight)


class FakeMacOS:
    def __init__(self):
        self.running = []
        self.calls = []
        self.fail = None
        self.result = {'token': 'hanq-permission-test', 'pid': 201, 'ax': True, 'post': True}

    def processes(self):
        return copy.deepcopy(self.running)

    def action(self, name):
        self.calls.append(name)
        if self.fail == name:
            raise preflight.PreflightError(f'{name} failed')

    def stop(self, processes):
        self.action('stop')
        self.running = []

    def reset(self):
        self.action('reset')

    def launch(self, app):
        self.action('launch')
        self.running = [{'pid': 200, 'app': app, 'helper': False,
                         'identity': (str(pathlib.Path(app) / 'Contents/MacOS/HanQ'), 'start')}]
        return 200

    def settings(self):
        self.action('settings')

    def probe(self, app):
        self.action('probe')
        return self.result


class PreparationTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory(prefix='hanq-preflight-tests-')
        self.addCleanup(self.directory.cleanup)
        self.root = pathlib.Path(self.directory.name)
        self.app = self.root / 'candidate with spaces/HanQ.app'
        (self.app / 'Contents/MacOS').mkdir(parents=True)
        self.info = {'CFBundleIdentifier': preflight.BUNDLE_ID, 'CFBundleExecutable': 'HanQ',
                     'CFBundleShortVersionString': '0.3.0', 'CFBundleVersion': '132',
                     'HanQReleaseVersion': '0.3.0-beta.1'}
        self.write_plist()
        self.binary = self.app / 'Contents/MacOS/HanQ'
        self.binary.write_bytes(b'fixture')
        self.binary.chmod(0o755)
        self.output = self.root / 'record'
        self.ops = FakeMacOS()
        self.contexts = contextlib.ExitStack()
        self.addCleanup(self.contexts.close)
        self.stdout = self.contexts.enter_context(contextlib.redirect_stdout(io.StringIO()))
        self.runner = self.contexts.enter_context(mock.patch.object(preflight, 'run', side_effect=self.command))

    def write_plist(self):
        (self.app / 'Contents/Info.plist').write_bytes(plistlib.dumps(self.info))

    def command(self, command):
        self.assertEqual(command[0], '/usr/bin/codesign')
        return subprocess.CompletedProcess(command, 0, '',
                                           'Identifier=taek.in.hanq\nCDHash=fixture\n')

    def prepare(self):
        return preflight.prepare(self.app, self.output, operations=self.ops)

    def record(self):
        return json.loads((self.output / 'record.json').read_text())

    def check(self):
        return preflight.check(self.output / 'record.json', operations=self.ops)

    def test_prepare_stops_before_reset_and_waits_for_gui(self):
        self.assertEqual(self.prepare(), 0)
        self.assertEqual(self.ops.calls, ['stop', 'reset', 'launch', 'settings'])
        record = self.record()
        self.assertEqual(record['status'], 'awaiting_approval')
        self.assertEqual(record['steps']['gui_approval'], 'pending')
        self.assertEqual(record['steps']['fresh_permission_check'], 'not_run')
        self.assertEqual(record['app']['path'], str(self.app.resolve()))

    def test_dry_run_has_no_side_effects_or_record(self):
        self.assertEqual(preflight.prepare(self.app, self.output, True, self.ops), 0)
        self.assertEqual(self.ops.calls, [])
        self.assertFalse(self.output.exists())
        self.assertFalse(json.loads(self.stdout.getvalue())['executed'])

    def test_wrong_bundle_id_never_stops_or_resets(self):
        self.info['CFBundleIdentifier'] = 'taek.in.hanq.tests'
        self.write_plist()
        with self.assertRaises(preflight.PreflightError):
            self.prepare()
        self.assertEqual(self.ops.calls, [])

    def test_invalid_signature_never_stops_or_resets(self):
        self.runner.side_effect = preflight.PreflightError('signature rejected')
        with self.assertRaises(preflight.PreflightError):
            self.prepare()
        self.assertEqual(self.ops.calls, [])

    def test_invalid_build_identity_never_stops_or_resets(self):
        self.info['CFBundleVersion'] = '0'
        self.write_plist()
        with self.assertRaises(preflight.PreflightError):
            self.prepare()
        self.assertEqual(self.ops.calls, [])

    def test_failure_to_stop_prevents_reset(self):
        self.ops.fail = 'stop'
        with self.assertRaises(preflight.PreflightError):
            self.prepare()
        self.assertEqual(self.ops.calls, ['stop'])
        self.assertEqual(self.record()['status'], 'failed')
        self.assertEqual(self.record()['steps']['accessibility_reset'], 'not_run')

    def test_reset_failure_prevents_launch_and_approval_claim(self):
        self.ops.fail = 'reset'
        with self.assertRaises(preflight.PreflightError):
            self.prepare()
        self.assertEqual(self.ops.calls, ['stop', 'reset'])
        self.assertEqual(self.record()['steps']['new_app_launched'], 'not_run')

    def test_reappearing_app_prevents_reset(self):
        self.ops.stop = lambda processes: None
        self.ops.running = [{'pid': 100, 'app': str(self.app), 'helper': False}]
        with self.assertRaises(preflight.PreflightError):
            self.prepare()
        self.assertEqual(self.ops.calls, [])

    def test_app_changed_during_prepare_prevents_reset(self):
        def stop(processes):
            self.binary.write_bytes(b'new build')
        self.ops.stop = stop
        with self.assertRaises(preflight.PreflightError):
            self.prepare()
        self.assertEqual(self.ops.calls, [])

    def test_settings_failure_still_allows_manual_navigation(self):
        self.ops.fail = 'settings'
        self.assertEqual(self.prepare(), 0)
        self.assertEqual(self.record()['status'], 'awaiting_approval')
        self.assertIn('settings_open_error', self.record())

    def test_record_directory_is_not_overwritten(self):
        self.prepare()
        before = (self.output / 'record.json').read_bytes()
        self.ops.calls.clear()
        with self.assertRaises(FileExistsError):
            self.prepare()
        self.assertEqual(self.ops.calls, [])
        self.assertEqual((self.output / 'record.json').read_bytes(), before)

    def test_check_requires_both_ax_and_event_posting(self):
        self.prepare()
        for ax, post in [(None, False), (True, False), (False, True)]:
            with self.subTest(ax=ax, post=post):
                self.ops.result.update(ax=ax, post=post)
                self.assertEqual(self.check(), 2)
                self.assertEqual(self.record()['status'], 'awaiting_approval')
        self.ops.result.update(ax=True, post=True)
        self.assertEqual(self.check(), 0)
        self.assertEqual(self.record()['status'], 'permissions_ready')

    def test_changed_binary_invalidates_previous_success_without_reset(self):
        self.prepare()
        self.check()
        self.ops.calls.clear()
        self.binary.write_bytes(b'new signed candidate')
        with self.assertRaises(preflight.PreflightError):
            self.check()
        record = self.record()
        self.assertEqual(record['status'], 'awaiting_approval')
        self.assertEqual(record['steps']['fresh_permission_check'], 'error')
        self.assertNotIn('permission_result', record)
        self.assertEqual(self.ops.calls, [])

    def test_other_running_hanq_blocks_probe(self):
        self.prepare()
        self.ops.running[0]['app'] = '/Applications/HanQ.app'
        self.ops.calls.clear()
        with self.assertRaises(preflight.PreflightError):
            self.check()
        self.assertEqual(self.ops.calls, [])

    def test_probe_error_is_not_reported_as_permission_denial_or_success(self):
        self.prepare()
        self.ops.fail = 'probe'
        with self.assertRaises(preflight.PreflightError):
            self.check()
        self.assertEqual(self.record()['steps']['fresh_permission_check'], 'error')

    def test_primary_process_change_during_probe_invalidates_check(self):
        self.prepare()
        def probe(app):
            self.ops.running[0]['pid'] = 300
            return self.ops.result
        self.ops.probe = probe
        with self.assertRaises(preflight.PreflightError):
            self.check()
        self.assertEqual(self.record()['steps']['fresh_permission_check'], 'error')

    def test_reset_is_limited_to_hanq_accessibility(self):
        operations = preflight.MacOS.__new__(preflight.MacOS)
        with mock.patch.object(preflight, 'run') as runner:
            operations.reset()
        runner.assert_called_once_with(['/usr/bin/tccutil', 'reset', 'Accessibility', 'taek.in.hanq'])

    def test_helpers_stop_first_and_reused_pid_is_not_signalled(self):
        operations = preflight.MacOS.__new__(preflight.MacOS)
        processes = [{'pid': 100, 'identity': ('app', 'main'), 'helper': False},
                     {'pid': 101, 'identity': ('app', 'helper'), 'helper': True},
                     {'pid': 102, 'identity': ('app', 'old'), 'helper': False}]
        operations.process_identity = lambda pid: {100: ('app', 'main'), 101: ('app', 'helper'),
                                                    102: ('other', 'new')}[pid]
        operations.processes = lambda: []
        with mock.patch.object(preflight.os, 'kill') as kill:
            operations.stop(processes)
        self.assertEqual([call.args[0] for call in kill.call_args_list], [101, 100])

    def test_fresh_probe_accepts_omitted_ax_when_post_is_denied(self):
        operations = preflight.MacOS.__new__(preflight.MacOS)
        def command(command):
            if command[0] == '/usr/bin/getconf':
                return subprocess.CompletedProcess(command, 0, str(self.root), '')
            directory = pathlib.Path(command[-1])
            result = {'token': directory.name, 'pid': 201, 'post': False}
            (directory / 'result.json').write_text(json.dumps(result))
            return subprocess.CompletedProcess(command, 0, '', '')
        with mock.patch.object(preflight, 'run', side_effect=command):
            result = operations.probe(str(self.app))
        self.assertIsNone(result['ax'])
        self.assertFalse(result['post'])

    def test_probe_rejects_wrong_token(self):
        operations = preflight.MacOS.__new__(preflight.MacOS)
        def command(command):
            if command[0] == '/usr/bin/getconf':
                return subprocess.CompletedProcess(command, 0, str(self.root), '')
            directory = pathlib.Path(command[-1])
            (directory / 'result.json').write_text(json.dumps(
                {'token': 'another-probe', 'pid': 201, 'post': True, 'ax': True}))
            return subprocess.CompletedProcess(command, 0, '', '')
        with mock.patch.object(preflight, 'run', side_effect=command):
            with self.assertRaises(preflight.PreflightError):
                operations.probe(str(self.app))

    def test_process_inventory_ignores_same_name_with_another_bundle_id(self):
        unrelated = self.root / 'unrelated/HanQ.app'
        (unrelated / 'Contents/MacOS').mkdir(parents=True)
        (unrelated / 'Contents/Info.plist').write_bytes(plistlib.dumps(
            {'CFBundleIdentifier': 'other.app'}))
        operations = preflight.MacOS.__new__(preflight.MacOS)
        operations.process_identity = lambda pid: (
            str((self.app if pid == 100 else unrelated) / 'Contents/MacOS/HanQ'), 'start')
        with mock.patch.object(preflight.subprocess, 'run', return_value=
                               subprocess.CompletedProcess([], 0, '100\n101\n', '')):
            with mock.patch.object(preflight, 'run', return_value=
                                   subprocess.CompletedProcess([], 0, '--permission-relauncher', '')):
                processes = operations.processes()
        self.assertEqual([item['pid'] for item in processes], [100])
        self.assertTrue(processes[0]['helper'])

    def reuse_fixture(self):
        self.prepare()
        self.check()
        archived = self.root / 'previous/HanQ.app'
        shutil.copytree(self.app, archived)
        self.binary.write_bytes(b'new candidate')
        self.ops.calls.clear()
        signature = {'certificateSHA1': 'A' * 40,
                     'designatedRequirement': 'identifier "taek.in.hanq" and certificate root = H"' + 'a' * 40 + '"'}
        self.signatures = self.contexts.enter_context(mock.patch.object(
            preflight, 'code_signature', return_value=signature))
        return archived

    def reuse(self, archived):
        return preflight.reuse_permissions(self.app, self.output / 'record.json', archived,
                                          self.root / 'reuse', operations=self.ops)

    def test_certificate_reuse_probes_before_launch_without_reset(self):
        archived = self.reuse_fixture()
        self.assertEqual(self.reuse(archived), 0)
        self.assertEqual(self.ops.calls, ['stop', 'probe', 'launch', 'probe'])
        record = json.loads((self.root / 'reuse/record.json').read_text())
        self.assertEqual(record['status'], 'permissions_ready')
        self.assertEqual(record['steps']['accessibility_reset'], 'not_performed_certificate_continuity')

    def test_reuse_rejects_changed_certificate_before_stopping(self):
        archived = self.reuse_fixture()
        self.signatures.side_effect = [dict(self.signatures.return_value),
                                      dict(self.signatures.return_value, certificateSHA1='B' * 40)]
        with self.assertRaises(preflight.PreflightError): self.reuse(archived)
        self.assertEqual(self.ops.calls, [])

    def test_reuse_rejects_adhoc_before_stopping(self):
        archived = self.reuse_fixture()
        self.signatures.return_value = {'certificateSHA1': None, 'designatedRequirement': 'cdhash H"abcd"'}
        with self.assertRaises(preflight.PreflightError): self.reuse(archived)
        self.assertEqual(self.ops.calls, [])

    def test_reuse_rejects_modified_previous_app(self):
        archived = self.reuse_fixture()
        (archived / 'Contents/MacOS/HanQ').write_bytes(b'not approved')
        with self.assertRaises(preflight.PreflightError): self.reuse(archived)
        self.assertEqual(self.ops.calls, [])

    def test_reuse_denied_permission_never_launches_or_resets(self):
        archived = self.reuse_fixture()
        self.ops.result.update(ax=False, post=False)
        with self.assertRaises(preflight.PreflightError): self.reuse(archived)
        self.assertEqual(self.ops.calls, ['stop', 'probe'])
        record = json.loads((self.root / 'reuse/record.json').read_text())
        self.assertEqual(record['status'], 'failed')
        self.assertEqual(record['steps']['new_app_launched'], 'not_run')

    def test_reuse_rejects_unapproved_baseline(self):
        archived = self.reuse_fixture()
        record = self.record(); record['status'] = 'awaiting_approval'
        (self.output / 'record.json').write_text(json.dumps(record))
        with self.assertRaises(preflight.PreflightError): self.reuse(archived)
        self.assertEqual(self.ops.calls, [])

    def test_reuse_rejects_new_path(self):
        archived = self.reuse_fixture()
        with self.assertRaises(preflight.PreflightError):
            preflight.reuse_permissions(archived, self.output / 'record.json', archived,
                                        self.root / 'reuse', operations=self.ops)
        self.assertEqual(self.ops.calls, [])


if __name__ == '__main__':
    unittest.main()

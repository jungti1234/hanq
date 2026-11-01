"""No apps/TCC/keys: verify that log readiness gates the preparation workflow."""
import copy
import json
import os
import pathlib
import uuid
import unittest
import test_prepare_app_test as common
preflight = common.preflight


class DiagnosticMacOS(common.FakeMacOS):
    def __init__(self):
        super().__init__()
        self.write_receipt = True
        self.diagnostic_ready = True
        self.receipt = None

    def diagnostic_probe(self, app, directory):
        self.action('diagnostic_probe')
        pathlib.Path(directory).mkdir(mode=0o700, exist_ok=True)
        return {'build': '132', 'readiness': {'ready': self.diagnostic_ready, 'reason': 'fixture'}}

    def launch_diagnostics(self, app, directory, token):
        pid = self.launch(app)
        self.receipt = pathlib.Path(directory) / f'.preflight-{token}.json'
        if self.write_receipt:
            self.receipt.write_text(json.dumps({'schema': 1, 'token': token, 'pid': pid,
                                              'build': '132', 'runID': str(uuid.uuid4()), 'ready': True}))
            self.receipt.chmod(0o600)
        return pid


class DiagnosticReadinessTests(unittest.TestCase):
    write_plist = common.PreparationTests.write_plist
    command = common.PreparationTests.command
    record = common.PreparationTests.record
    check = common.PreparationTests.check
    def setUp(self):
        common.PreparationTests.setUp(self)
        self.info['HanQDiagnosticReadinessVersion'] = 1
        self.write_plist()
        self.ops = DiagnosticMacOS()
        self.logs = self.root / 'private-logs/incidents'

    def prepare_diagnostics(self):
        return preflight.prepare(self.app, self.output, operations=self.ops, diagnostics=self.logs)

    def test_diagnostic_storage_is_checked_before_stop_or_reset(self):
        self.assertEqual(self.prepare_diagnostics(), 0)
        self.assertEqual(self.ops.calls[:3], ['diagnostic_probe', 'stop', 'reset'])
        self.assertEqual(self.logs.parent.stat().st_mode & 0o777, 0o700)
        self.assertEqual(self.check(), 0)
        self.assertEqual(self.record()['status'], 'input_test_ready')
        self.assertEqual(self.record()['diagnostics']['status'], 'verified_current_process')

    def test_bad_parent_preserves_running_app_and_permissions(self):
        self.logs.parent.mkdir(mode=0o755)
        self.ops.running = [{'pid': 77, 'app': 'existing', 'helper': False}]
        before = copy.deepcopy(self.ops.running)
        with self.assertRaises(preflight.PreflightError):
            self.prepare_diagnostics()
        self.assertEqual(self.ops.calls, [])
        self.assertEqual(self.ops.running, before)
        self.assertEqual(self.logs.parent.stat().st_mode & 0o777, 0o755)

    def test_real_app_storage_denial_prevents_stop(self):
        self.ops.diagnostic_ready = False
        with self.assertRaises(preflight.PreflightError):
            self.prepare_diagnostics()
        self.assertEqual(self.ops.calls, ['diagnostic_probe'])
        self.assertEqual(self.record()['steps']['previous_app_stopped'], 'not_run')

    def test_unsupported_app_never_launches_unknown_probe(self):
        del self.info['HanQDiagnosticReadinessVersion']
        self.write_plist()
        with self.assertRaises(preflight.PreflightError):
            self.prepare_diagnostics()
        self.assertEqual(self.ops.calls, [])

    def test_boolean_capability_never_launches_unknown_probe(self):
        self.info['HanQDiagnosticReadinessVersion'] = True
        self.write_plist()
        with self.assertRaises(preflight.PreflightError):
            self.prepare_diagnostics()
        self.assertEqual(self.ops.calls, [])

    def test_readonly_directory_revokes_input_ready(self):
        self.prepare_diagnostics()
        self.check()
        self.logs.chmod(0o500)
        try:
            with self.assertRaises(preflight.PreflightError):
                self.check()
            self.assertEqual(self.record()['status'], 'awaiting_diagnostics')
        finally:
            self.logs.chmod(0o700)

    def test_ax_success_without_saved_receipt_is_not_input_ready(self):
        self.ops.write_receipt = False
        self.prepare_diagnostics()
        with self.assertRaises(OSError):
            self.check()
        self.assertEqual(self.record()['status'], 'awaiting_diagnostics')
        self.assertNotIn('permission_result', self.record())

    def test_wrong_receipt_identity_never_reuses_success(self):
        self.prepare_diagnostics()
        self.check()
        original = json.loads(self.ops.receipt.read_text())
        for key, value in [('pid', 999), ('build', '131'), ('token', str(uuid.uuid4())), ('ready', False), ('runID', 'bad'), ('schema', True)]:
            changed = dict(original, **{key: value})
            self.ops.receipt.write_text(json.dumps(changed))
            with self.assertRaises(preflight.PreflightError):
                self.check()
            self.assertNotEqual(self.record()['status'], 'input_test_ready')
            self.assertNotIn('receipt', self.record()['diagnostics'])

    def test_changed_main_cannot_use_the_old_receipt(self):
        self.prepare_diagnostics()
        self.ops.running[0]['pid'] += 1
        with self.assertRaises(preflight.PreflightError):
            self.check()
        self.assertEqual(self.record()['status'], 'awaiting_diagnostics')

    def test_receipt_symlink_is_rejected(self):
        self.prepare_diagnostics()
        other = self.root / 'other.json'
        self.ops.receipt.rename(other)
        self.ops.receipt.symlink_to(other)
        with self.assertRaises(OSError):
            self.check()

    def test_world_readable_receipt_is_rejected(self):
        self.prepare_diagnostics()
        self.ops.receipt.chmod(0o644)
        with self.assertRaises(preflight.PreflightError):
            self.check()

    def test_directory_swap_after_preparation_invalidates_ready(self):
        self.prepare_diagnostics()
        self.logs.parent.chmod(0o755)
        with self.assertRaises(preflight.PreflightError):
            self.check()

    def test_dry_run_does_not_create_diagnostic_directory(self):
        self.assertEqual(preflight.prepare(self.app, self.output, True, self.ops, diagnostics=self.logs), 0)
        self.assertFalse(self.logs.parent.exists())
        self.assertEqual(self.ops.calls, [])

    def test_investigation_cannot_accept_a_permission_only_record(self):
        preflight.prepare(self.app, self.output, operations=self.ops)
        with self.assertRaises(preflight.PreflightError):
            preflight.check(self.output / 'record.json', operations=self.ops, require_diagnostics=True)

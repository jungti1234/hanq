#!/usr/bin/env python3
"""Prepare one HanQ build for input tests; Accessibility approval stays manual."""
import argparse
import ctypes
import datetime
import hashlib
import json
import os
import pathlib
import plistlib
import re
import shlex
import signal
import subprocess
import sys
import tempfile
import time
import uuid

BUNDLE_ID = 'taek.in.hanq'
SETTINGS_URL = 'x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility'
ROOT = pathlib.Path(__file__).resolve().parent.parent


class PreflightError(RuntimeError):
    pass


def run(command):
    try:
        result = subprocess.run(command, capture_output=True, text=True, timeout=15)
    except (OSError, subprocess.TimeoutExpired) as error:
        raise PreflightError(str(error)) from error
    if result.returncode:
        raise PreflightError(result.stderr.strip() or result.stdout.strip() or
                             f'명령 실패: {shlex.join(command)} ({result.returncode})')
    return result


def app_identity(app):
    app = pathlib.Path(app).expanduser().resolve()
    plist = app / 'Contents/Info.plist'
    executable = app / 'Contents/MacOS/HanQ'
    try:
        plist_bytes = plist.read_bytes()
        info = plistlib.loads(plist_bytes)
        if (app.suffix != '.app' or info.get('CFBundleIdentifier') != BUNDLE_ID or
                info.get('CFBundleExecutable') != 'HanQ' or not executable.is_file() or
                not os.access(executable, os.X_OK)):
            raise PreflightError('실행 가능한 한Q 앱 번들이 아닙니다.')
        version = info.get('CFBundleShortVersionString', '')
        build = info.get('CFBundleVersion', '')
        release = info.get('HanQReleaseVersion', '')
        if (not isinstance(version, str) or not re.fullmatch(r'\d+\.\d+\.\d+', version) or
                not isinstance(build, str) or not re.fullmatch(r'[1-9]\d*', build) or
                not isinstance(release, str) or
                not re.fullmatch(re.escape(version) + r'(?:-beta\.[1-9]\d*)?', release)):
            raise PreflightError('앱의 버전·빌드 번호를 확인할 수 없습니다.')
        run(['/usr/bin/codesign', '--verify', '--deep', '--strict', str(app)])
        signature = run(['/usr/bin/codesign', '--display', '--verbose=4', str(app)])
        fields = dict(line.split('=', 1) for line in signature.stderr.splitlines() if '=' in line)
        if fields.get('Identifier') != BUNDLE_ID or not fields.get('CDHash'):
            raise PreflightError('한Q의 코드 서명 식별값을 확인할 수 없습니다.')
        return {'path': str(app), 'bundle_id': BUNDLE_ID, 'version': version,
                'release_version': release, 'build_number': build, 'cdhash': fields['CDHash'],
                'executable_sha256': hashlib.sha256(executable.read_bytes()).hexdigest(),
                'plist_sha256': hashlib.sha256(plist_bytes).hexdigest()}
    except (OSError, plistlib.InvalidFileException, ValueError) as error:
        raise PreflightError(f'앱 확인 실패: {error}') from error


class MacOS:
    def __init__(self):
        self.libproc = ctypes.CDLL('/usr/lib/libproc.dylib')
        self.libproc.proc_pidpath.argtypes = [ctypes.c_int, ctypes.c_void_p, ctypes.c_uint32]
        self.libproc.proc_pidpath.restype = ctypes.c_int

    def process_identity(self, pid):
        buffer = ctypes.create_string_buffer(4096)
        if self.libproc.proc_pidpath(pid, buffer, len(buffer)) <= 0:
            try:
                os.kill(pid, 0)
            except ProcessLookupError:
                return None
            raise PreflightError(f'프로세스 {pid}의 실행 경로를 확인할 수 없습니다.')
        started = run(['/bin/ps', '-p', str(pid), '-o', 'lstart=']).stdout.strip()
        return (str(pathlib.Path(buffer.value.decode()).resolve()), started)

    def processes(self):
        result = subprocess.run(['/usr/bin/pgrep', '-x', 'HanQ'], capture_output=True, text=True)
        if result.returncode not in (0, 1):
            raise PreflightError('한Q 프로세스 목록을 확인할 수 없습니다.')
        processes = []
        for item in result.stdout.split():
            pid = int(item)
            identity = self.process_identity(pid)
            if identity is None:
                continue
            executable = pathlib.Path(identity[0])
            if executable.parts[-3:] != ('Contents', 'MacOS', 'HanQ'):
                continue
            app = executable.parents[2]
            try:
                info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
            except (OSError, plistlib.InvalidFileException, ValueError) as error:
                raise PreflightError(f'실행 중인 앱의 번들을 확인할 수 없습니다: {app}') from error
            if info.get('CFBundleIdentifier') != BUNDLE_ID:
                continue
            command = run(['/bin/ps', '-p', str(pid), '-o', 'command=']).stdout
            helper = any(flag in command for flag in ('--permission-probe', '--permission-relauncher'))
            processes.append({'pid': pid, 'identity': identity, 'app': str(app), 'helper': helper})
        return processes

    def stop(self, processes):
        # Stop relaunch helpers first so a pending recovery cannot reopen the old app.
        for process in sorted(processes, key=lambda item: not item['helper']):
            if self.process_identity(process['pid']) != process['identity']:
                continue
            try:
                os.kill(process['pid'], signal.SIGTERM)
            except ProcessLookupError:
                pass
        end = time.monotonic() + 5
        while time.monotonic() < end:
            if not self.processes():
                return
            time.sleep(0.1)
        raise PreflightError('기존 한Q가 종료되지 않았습니다. 권한 초기화를 중단합니다.')

    def reset(self):
        run(['/usr/bin/tccutil', 'reset', 'Accessibility', BUNDLE_ID])

    def launch(self, app):
        run(['/usr/bin/open', '-n', app])
        end = time.monotonic() + 5
        while time.monotonic() < end:
            main = [item for item in self.processes() if not item['helper']]
            if len(main) == 1 and main[0]['app'] == app:
                return main[0]['pid']
            time.sleep(0.1)
        raise PreflightError('지정한 새 한Q의 실행을 확인할 수 없습니다.')

    def settings(self):
        run(['/usr/bin/open', SETTINGS_URL])

    def probe(self, app):
        # Use the OS temp path without resolving /var symlinks: the app validates
        # this directory against FileManager.default.temporaryDirectory.
        temporary_root = run(['/usr/bin/getconf', 'DARWIN_USER_TEMP_DIR']).stdout.strip()
        with tempfile.TemporaryDirectory(prefix='hanq-permission-', dir=temporary_root) as directory:
            run(['/usr/bin/open', '-n', '-g', app, '--args', '--permission-probe', directory])
            result_path = pathlib.Path(directory) / 'result.json'
            end = time.monotonic() + 5
            while time.monotonic() < end:
                if result_path.exists():
                    result = json.loads(result_path.read_text())
                    if (result.get('token') != pathlib.Path(directory).name or
                            type(result.get('pid')) is not int or result['pid'] <= 1 or
                            type(result.get('post')) is not bool or
                            (result.get('ax') is not None and type(result['ax']) is not bool)):
                        raise PreflightError('새 앱의 권한 검사 응답이 유효하지 않습니다.')
                    # Swift's JSONEncoder omits a nil optional AX value when
                    # event posting is denied, rather than writing JSON null.
                    result.setdefault('ax', None)
                    return result
                time.sleep(0.05)
        raise PreflightError('새 앱의 권한 검사 응답 시간이 초과됐습니다.')


def save_record(path, record):
    path = pathlib.Path(path)
    # Atomic replacement keeps interrupted checks from leaving a partial JSON file.
    with tempfile.NamedTemporaryFile(mode='w', encoding='utf-8', dir=path.parent,
                                     prefix='.preflight-', delete=False) as stream:
        temporary = pathlib.Path(stream.name)
        json.dump(record, stream, ensure_ascii=False, indent=2)
        stream.write('\n')
    try:
        os.replace(temporary, path)
    finally:
        temporary.unlink(missing_ok=True)


def ensure_same_app(identity):
    if app_identity(identity['path']) != identity:
        raise PreflightError('준비한 앱의 내용이 바뀌었습니다. 새 기록으로 다시 준비하세요.')


def code_signature(app):
    return json.loads(run([sys.executable, str(ROOT / 'scripts/sign-app.py'),
                           '--inspect', str(app)]).stdout)


def reuse_permissions(app, previous_record, previous_app, output=None, operations=None):
    """Verify certificate continuity and real permission before launching a new main app."""
    identity = app_identity(app)
    baseline = json.loads(pathlib.Path(previous_record).read_text())
    if (baseline.get('kind') != 'hanq-app-test-preflight' or
            baseline.get('status') != 'permissions_ready' or
            baseline.get('permission_result', {}).get('ax') is not True or
            baseline.get('permission_result', {}).get('post') is not True):
        raise PreflightError('승인·검사가 완료된 이전 준비 기록이 필요합니다.')
    if identity['path'] != baseline['app']['path']:
        raise PreflightError('권한 재사용은 이전에 승인한 동일 앱 경로에서만 검사합니다.')
    archived = app_identity(previous_app)
    if dict(archived, path=baseline['app']['path']) != baseline['app']:
        raise PreflightError('이전 앱 사본이 승인 당시 기록과 다릅니다.')
    old_signature, new_signature = code_signature(previous_app), code_signature(app)
    if (not old_signature.get('certificateSHA1') or
            old_signature['certificateSHA1'] != new_signature.get('certificateSHA1') or
            old_signature['designatedRequirement'] != new_signature.get('designatedRequirement') or
            'cdhash' in old_signature['designatedRequirement']):
        raise PreflightError('동일 인증서와 안정적인 서명 식별 조건을 확인할 수 없습니다.')
    operations = operations or MacOS()
    output = pathlib.Path(output or ROOT / '.build/hanq/test-preflight' / uuid.uuid4().hex).resolve()
    output.mkdir(parents=True, exist_ok=False)
    record_path = output / 'record.json'
    record = {'schema_version': 1, 'kind': 'hanq-app-test-preflight', 'app': identity,
              'created_at': datetime.datetime.now(datetime.timezone.utc).isoformat(),
              'status': 'preparing', 'previous_record': str(pathlib.Path(previous_record).resolve()),
              'code_signature': new_signature, 'steps': {'previous_app_stopped': 'not_run',
              'accessibility_reset': 'not_performed_certificate_continuity',
              'new_app_launched': 'not_run', 'gui_approval': 'previous_approval_pending_verification',
              'fresh_permission_check': 'not_run'}}
    save_record(record_path, record)
    try:
        operations.stop(operations.processes())
        record['steps']['previous_app_stopped'] = 'completed'
        ensure_same_app(identity)
        if operations.processes():
            raise PreflightError('다른 한Q가 실행 중입니다.')
        result = operations.probe(identity['path'])
        record['permission_result'] = result
        ensure_same_app(identity)
        if result.get('ax') is not True or result.get('post') is not True:
            raise PreflightError('권한이 유지되지 않았습니다. 일반 prepare와 GUI 승인이 필요합니다.')
        record['steps']['fresh_permission_check'] = 'passed_before_launch'
        record['steps']['gui_approval'] = 'previous_approval_verified'
        record['launched_pid'] = operations.launch(identity['path'])
        record['steps']['new_app_launched'] = 'completed'
        record['status'] = 'awaiting_approval'
        save_record(record_path, record)
        return check(record_path, operations=operations)
    except Exception as error:
        record['status'] = 'failed'
        record['error'] = str(error)
        save_record(record_path, record)
        raise


def prepare(app, output=None, dry_run=False, operations=None):
    identity = app_identity(app)
    operations = operations or MacOS()
    processes = operations.processes()
    if dry_run:
        print(json.dumps({'app': identity, 'hanq_processes_to_stop': len(processes),
                          'plan': ['한Q 종료 및 잔여 프로세스 확인',
                                   f'tccutil reset Accessibility {BUNDLE_ID}',
                                   shlex.join(['open', '-n', identity['path']]),
                                   '손쉬운 사용 설정 열기 및 사용자 승인 대기'],
                          'executed': False}, ensure_ascii=False, indent=2))
        return 0
    if output is None:
        output = ROOT / '.build/hanq/test-preflight' / uuid.uuid4().hex
    output = pathlib.Path(output).expanduser().resolve()
    output.mkdir(parents=True, exist_ok=False)
    record_path = output / 'record.json'
    record = {'schema_version': 1, 'kind': 'hanq-app-test-preflight', 'app': identity,
              'created_at': datetime.datetime.now(datetime.timezone.utc).isoformat(),
              'status': 'preparing', 'steps': {'previous_app_stopped': 'not_run',
              'accessibility_reset': 'not_run', 'new_app_launched': 'not_run',
              'gui_approval': 'pending', 'fresh_permission_check': 'not_run'}}
    save_record(record_path, record)
    try:
        operations.stop(processes)
        record['steps']['previous_app_stopped'] = 'completed'
        save_record(record_path, record)
        ensure_same_app(identity)
        if operations.processes():
            raise PreflightError('한Q가 다시 실행되어 권한 초기화를 중단합니다.')
        operations.reset()
        record['steps']['accessibility_reset'] = 'completed'
        save_record(record_path, record)
        ensure_same_app(identity)
        if operations.processes():
            raise PreflightError('다른 한Q가 실행되어 새 앱 실행을 중단합니다.')
        record['launched_pid'] = operations.launch(identity['path'])
        record['steps']['new_app_launched'] = 'completed'
        record['status'] = 'awaiting_approval'
        try:
            operations.settings()
        except PreflightError as error:
            record['settings_open_error'] = str(error)
        save_record(record_path, record)
    except Exception as error:
        record['status'] = 'failed'
        record['error'] = str(error)
        save_record(record_path, record)
        raise
    print(f"준비 완료: {identity['release_version']} ({identity['build_number']})\n{identity['path']}")
    print('손쉬운 사용에서 이 앱의 권한을 ON으로 승인하세요. 목록에 없으면 +로 위 앱을 추가하세요.')
    print('초기화는 GUI 목록 삭제 확인과 다릅니다. 기존 항목 혼선이 있으면 GUI에서 제거·재추가하세요.')
    if record.get('settings_open_error'):
        print('시스템 설정을 자동으로 열지 못했습니다. 개인정보 보호 및 보안 → 손쉬운 사용을 여세요.')
    print('승인 후 실행: ' + shlex.join(['python3', str(ROOT / 'scripts/prepare-app-test.py'),
                                       'check', str(record_path)]))
    return 0


def check(record_path, operations=None):
    record_path = pathlib.Path(record_path).expanduser().resolve()
    record = json.loads(record_path.read_text())
    steps = record.get('steps', {})
    reset_ready = steps.get('accessibility_reset') == 'completed' or (
        steps.get('accessibility_reset') == 'not_performed_certificate_continuity' and
        bool(record.get('code_signature', {}).get('certificateSHA1')) and
        bool(record.get('previous_record')))
    if (record.get('schema_version') != 1 or record.get('kind') != 'hanq-app-test-preflight' or
            record.get('status') not in ('awaiting_approval', 'permissions_ready') or
            not reset_ready or
            not all(steps.get(key) == 'completed' for key in
                    ('previous_app_stopped', 'new_app_launched'))):
        raise PreflightError('준비가 완료된 기록이 아닙니다. prepare부터 다시 실행하세요.')
    identity = record['app']
    try:
        ensure_same_app(identity)
        operations = operations or MacOS()
        main = [item for item in operations.processes() if not item['helper']]
        if len(main) != 1 or main[0]['app'] != identity['path']:
            raise PreflightError('준비한 경로의 한Q만 실행 중이어야 합니다.')
        result = operations.probe(identity['path'])
        ensure_same_app(identity)
        current_main = [item for item in operations.processes() if not item['helper']]
        if current_main != main:
            raise PreflightError('권한 검사 중 실행 중인 한Q가 바뀌었습니다. 다시 check하세요.')
        ready = result['ax'] is True and result['post'] is True
        record.pop('error', None)
        record['checked_at'] = datetime.datetime.now(datetime.timezone.utc).isoformat()
        record['permission_result'] = result
        record['main_pid'] = main[0]['pid']
        record['steps']['gui_approval'] = 'verified_by_permission_probe' if ready else 'pending'
        record['steps']['fresh_permission_check'] = 'passed' if ready else 'denied'
        record['status'] = 'permissions_ready' if ready else 'awaiting_approval'
        save_record(record_path, record)
    except Exception as error:
        # Keep the preparation record reusable after a transient check failure,
        # but invalidate any earlier permission success.
        record['status'] = 'awaiting_approval'
        record['steps']['fresh_permission_check'] = 'error'
        record['steps']['gui_approval'] = 'unconfirmed'
        record.pop('permission_result', None)
        record['error'] = str(error)
        save_record(record_path, record)
        raise
    print(f"{identity['release_version']} ({identity['build_number']}) · AX={result['ax']} · post={result['post']}")
    print(f'기록: {record_path}')
    if not ready:
        print('권한 미허용: GUI에서 승인한 뒤 다시 check하세요. 실제 입력 테스트는 아직 시작하지 마세요.')
        return 2
    print('새 빌드의 권한 확인 완료. 앱의 입력 감시·실제 입력 동작은 별도로 확인하세요.')
    return 0


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest='command', required=True)
    prepare_parser = commands.add_parser('prepare', help='기존 한Q 종료·권한 초기화·새 앱 실행')
    prepare_parser.add_argument('app', type=pathlib.Path)
    prepare_parser.add_argument('--output', type=pathlib.Path, help='새 기록 디렉터리 (기존 경로 덮어쓰기 금지)')
    prepare_parser.add_argument('--dry-run', action='store_true', help='앱 확인과 계획 출력만 수행')
    prepare_parser.add_argument('--reuse-permissions-from', type=pathlib.Path,
                                help='같은 인증서·경로의 이전 승인 기록 (초기화 없이 실제 권한 검사)')
    prepare_parser.add_argument('--previous-app', type=pathlib.Path, help='승인 당시의 보존된 앱 사본')
    check_parser = commands.add_parser('check', help='GUI 승인 후 새 앱의 권한 확인')
    check_parser.add_argument('record', type=pathlib.Path)
    args = parser.parse_args()
    try:
        if args.command == 'prepare':
            if args.reuse_permissions_from or args.previous_app:
                if not (args.reuse_permissions_from and args.previous_app) or args.dry_run:
                    raise PreflightError('재사용 검사는 이전 기록·앱 사본이 모두 필요하며 dry-run과 함께 사용할 수 없습니다.')
                return reuse_permissions(args.app, args.reuse_permissions_from, args.previous_app, args.output)
            return prepare(args.app, args.output, args.dry_run)
        return check(args.record)
    except (PreflightError, OSError, ValueError, KeyError) as error:
        print(f'오류: {error}', file=sys.stderr)
        return 1


if __name__ == '__main__':
    sys.exit(main())

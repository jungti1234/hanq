#!/usr/bin/env python3
"""Explicit same-window retries for the owned source fixture only."""
import ctypes
import json
import os
import pathlib
import runpy
import subprocess
import sys
import time


class Timebase(ctypes.Structure):
    _fields_ = [('numer', ctypes.c_uint32), ('denom', ctypes.c_uint32)]


def source_uptime():
    # Python's monotonic epoch need not equal Foundation's uptime epoch.
    system = ctypes.CDLL('/usr/lib/libSystem.B.dylib')
    system.mach_absolute_time.restype = ctypes.c_uint64
    base = Timebase()
    if system.mach_timebase_info(ctypes.byref(base)) != 0 or not base.denom:
        raise RuntimeError('source fixture clock unavailable')
    return system.mach_absolute_time() * base.numer / base.denom / 1_000_000_000


def owned_request(root, request, progress, identity, now):
    expected = root / 'SourceInteractionFixture.app/Contents/MacOS/SourceInteractionFixture'
    return (isinstance(request.get('nonce'), str) and len(request['nonce']) == 36
            and request.get('pid') == progress.get('pid')
            and request.get('generation') == progress.get('generation')
            and progress.get('active') is True
            and progress.get('firstResponderIsField') is True
            and 0 <= now - progress.get('observedAt', -100) < 1.2
            and identity is not None and identity[0] == str(expected))


def atomic_json(path, value):
    temporary = path.with_suffix('.new')
    temporary.write_text(json.dumps(value))
    os.replace(temporary, path)


def main():
    root = pathlib.Path(sys.argv[1]).resolve()
    diagnostics = pathlib.Path(sys.argv[2])
    expected_app = str(pathlib.Path(sys.argv[3]).resolve())
    if root.parent != pathlib.Path('/private/tmp') or not root.name.startswith('hanq-source-live.'):
        return 2
    helper = runpy.run_path(str(root / 'prepare-app-test.py'))
    ops = helper['MacOS']()
    record_path = root / 'preflight.json'
    initial = json.loads(record_path.read_text())
    if initial['app']['path'] != expected_app:
        return 2
    identity = initial['app']
    handled = None
    print('START: detached retry helper', os.getpid(), flush=True)
    launch_deadline = time.monotonic() + 15
    while not (root / 'stop').exists():
        # Stay available as long as the owned window lives, including when the
        # user returns after hours. A crashed/force-quit window ends the helper.
        progress_path = root / 'progress.json'
        if progress_path.exists():
            try:
                current = json.loads(progress_path.read_text())
                fixture = ops.process_identity(current['pid'])
                expected = str(root / 'SourceInteractionFixture.app/Contents/MacOS/SourceInteractionFixture')
                if fixture is None or fixture[0] != expected:
                    print('STOP: owned fixture exited', flush=True)
                    break
            except (ValueError, KeyError):
                pass
        elif time.monotonic() > launch_deadline:
            print('STOP: fixture launch timeout', flush=True)
            break
        try:
            request = json.loads((root / 'retry-request.json').read_text())
            if request.get('nonce') == handled:
                time.sleep(.1)
                continue
            handled = request.get('nonce')
            progress = json.loads((root / 'progress.json').read_text())
            fixture_identity = ops.process_identity(progress['pid'])
            if not owned_request(root, request, progress, fixture_identity, source_uptime()):
                raise RuntimeError('owned fixture is no longer active or request is stale')
            # Inspect the exact same approved app, then recheck foreground proof.
            helper['ensure_same_app'](identity)
            if helper['check'](record_path, operations=ops) != 0:
                raise RuntimeError('fresh AX/post check failed')
            progress = json.loads((root / 'progress.json').read_text())
            if not owned_request(root, request, progress, ops.process_identity(progress['pid']), source_uptime()):
                raise RuntimeError('owned fixture lost focus before reprepare')
            if (root / 'stop').exists():
                break
            processes = ops.processes()
            if any(p['app'] != expected_app for p in processes):
                raise RuntimeError('unexpected HanQ path')
            ops.stop(processes)
            # Only HanQ is relaunched; the editor, step and attempt history stay.
            subprocess.run(['/usr/bin/open', '-n', '-g', expected_app, '--args', '--diagnose-input', str(diagnostics)], check=True)
            deadline = time.monotonic() + 5
            while time.monotonic() < deadline:
                if any(not p['helper'] for p in ops.processes()):
                    break
                time.sleep(.05)
            if helper['check'](record_path, operations=ops) != 0:
                raise RuntimeError('restarted process permissions unavailable')
            record = json.loads(record_path.read_text())
            atomic_json(root / 'retry-ready.json', {'nonce': handled, 'pid': record['main_pid'], 'passed': True})
            print('PASS: same-window retry reprepare and fresh permissions', flush=True)
        except FileNotFoundError:
            pass
        except Exception as error:
            atomic_json(root / 'retry-ready.json', {'nonce': handled, 'passed': False})
            print('FAIL: retry reprepare:', str(error), flush=True)
        time.sleep(.1)
    print('STOP: retry helper finished', flush=True)
    return 0


if __name__ == '__main__':
    raise SystemExit(main())

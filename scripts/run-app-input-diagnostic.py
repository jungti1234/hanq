#!/usr/bin/env python3
"""Launch via LaunchServices (not a shell child), with an external kill deadline."""
import argparse
import ctypes
import json
import os
import pathlib
import signal
import subprocess
import time

parser = argparse.ArgumentParser()
parser.add_argument('--seconds', type=float, default=20)
parser.add_argument('--output', type=pathlib.Path, required=True)
parser.add_argument('--no-trace', action='store_true', help='Run normal app without extra diagnostic permission queries')
parser.add_argument('--follow-recovery', action='store_true', help='Keep the external deadline for automatic recovery instances too')
parser.add_argument('app', type=pathlib.Path)
args = parser.parse_args()
if not 0 < args.seconds <= 120:
    parser.error('deadline must be in (0, 120] seconds')
app = args.app.resolve()
executable = str(app / 'Contents/MacOS/HanQ')
libproc = ctypes.CDLL('/usr/lib/libproc.dylib')
def pids():
    result = subprocess.run(['pgrep', '-x', 'HanQ'], capture_output=True, text=True)
    if result.returncode not in (0, 1):
        raise RuntimeError('Cannot inspect HanQ process list')
    return [int(item) for item in result.stdout.split()]
def identity(pid):
    buf = ctypes.create_string_buffer(4096)
    if libproc.proc_pidpath(pid, buf, len(buf)) <= 0:
        return None
    started = subprocess.run(['ps', '-p', str(pid), '-o', 'lstart='], capture_output=True, text=True).stdout.strip()
    return (buf.value.decode(), started)
if pids():
    parser.error('Quit HanQ before starting this controlled run')
args.output.mkdir(parents=True, exist_ok=False)
trace = str(args.output.resolve() / 'trace.log')
with (args.output / 'supervisor.jsonl').open('w') as log:
    def record(event, **fields):
        log.write(json.dumps(dict(time=time.time(), event=event, **fields)) + '\n')
        log.flush()
    command = ['open', '-n', str(app)]
    if not args.no_trace:
        command += ['--args', '--diagnose-input', trace]
    subprocess.run(command, check=True)
    pid = None
    deadline = time.monotonic() + 5
    while time.monotonic() < deadline:
        matches = [(item, identity(item)) for item in pids()]
        matches = [(item, ident) for item, ident in matches if ident and ident[0] == executable
                   and not any(flag in subprocess.run(
                       ['ps', '-p', str(item), '-o', 'command='], capture_output=True, text=True).stdout
                               for flag in ('--permission-probe', '--permission-relauncher'))]
        if len(matches) == 1:
            pid, original = matches[0]
            break
        time.sleep(0.05)
    if pid is None:
        raise RuntimeError('LaunchServices did not produce a matching HanQ process')
    record('started', pid=pid, identity=original, deadline_seconds=args.seconds, trace_enabled=not args.no_trace)
    print(f'LaunchServices HanQ PID {pid}; forced stop in {args.seconds:g}s', flush=True)
    tracked = {pid: original}
    exited = set()
    def stop_tracked():
        for item, ident in tracked.items():
            if identity(item) == ident:
                try:
                    os.kill(item, signal.SIGKILL)
                except ProcessLookupError:
                    pass
    try:
        end = time.monotonic() + args.seconds
        while time.monotonic() < end:
            if args.follow_recovery:
                for item in pids():
                    if item in tracked:
                        continue
                    ident = identity(item)
                    command = subprocess.run(['ps', '-p', str(item), '-o', 'command='], capture_output=True, text=True).stdout
                    if ident and ident[0] == executable and '--permission-recovery' in command:
                        tracked[item] = ident
                        record('recovered', pid=item, identity=ident)
                if len(tracked) > 3:
                    record('restart-loop', count=len(tracked))
                    break
            for item, ident in tracked.items():
                if item not in exited and identity(item) != ident:
                    record('exited', pid=item)
                    exited.add(item)
            if pid in exited and not args.follow_recovery:
                break
            time.sleep(0.05)
        else:
            for item, ident in tracked.items():
                if identity(item) == ident:
                    record('deadline.kill', pid=item)
    finally:
        stop_tracked()
        record('finished', pid=pid)

#!/usr/bin/env python3
"""Launch one diagnostic child and kill only that child at a fixed deadline.

No UI automation or permission changes. The watchdog is outside HanQ, so a
stalled/suspended app cannot prevent the deadline. Logs contain no typed input.
"""
import argparse
import json
import pathlib
import subprocess
import time

parser = argparse.ArgumentParser()
parser.add_argument('--seconds', type=float, default=30)
parser.add_argument('--output', type=pathlib.Path, required=True)
parser.add_argument('command', nargs=argparse.REMAINDER)
args = parser.parse_args()
command = args.command
if command[:1] == ['--']:
    command = command[1:]
if not command or not 0 < args.seconds <= 120:
    parser.error('Provide a command and a deadline in (0, 120] seconds')
args.output.mkdir(parents=True, exist_ok=False)
with (args.output / 'supervisor.jsonl').open('w') as log:
    def record(event, **values):
        log.write(json.dumps(dict(time=time.time(), event=event, **values)) + '\n')
        log.flush()
    with (args.output / 'stderr.log').open('wb') as stderr:
        child = subprocess.Popen(command, stdout=stderr, stderr=stderr)
        record('started', pid=child.pid, deadline_seconds=args.seconds)
        print(f'Diagnostic child PID {child.pid}; forced stop in {args.seconds:g}s', flush=True)
        try:
            try:
                result = child.wait(timeout=args.seconds)
                record('exited', returncode=result)
            except subprocess.TimeoutExpired:
                record('deadline.kill', pid=child.pid)
                child.kill()
                result = child.wait(timeout=5)
                record('killed', returncode=result)
        finally:
            if child.poll() is None:
                child.kill()
                child.wait(timeout=5)

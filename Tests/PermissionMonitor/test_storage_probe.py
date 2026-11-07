"""Exercise the real storage probe entrypoint without apps, TCC or input hooks."""
import json
import os
import pathlib
import shutil
import stat
import subprocess
import sys
import tempfile

binary = pathlib.Path(sys.argv[1])
for case in ('valid', 'public-directory', 'linked-directory', 'existing-result'):
    with tempfile.TemporaryDirectory(prefix='hanq-storage-', dir='/private/tmp') as value:
        root = pathlib.Path(value)
        assert root.resolve() == root and stat.S_IMODE(root.stat().st_mode) == 0o700
        executable = root / 'storage-probe'
        shutil.copy2(binary, executable)
        workspace = root
        result = root / 'result.json'
        if case == 'public-directory':
            root.chmod(0o755)
        if case == 'linked-directory':
            workspace = root / 'hanq-storage-linked'
            workspace.symlink_to(root, target_is_directory=True)
        if case == 'existing-result':
            result.write_text('keep');result.chmod(0o600)
        process = subprocess.run([str(executable), '--diagnostic-storage-probe', str(workspace),
                                  '--bounded-input-incidents', str(root / 'runtime')],
                                 cwd=root, capture_output=True, timeout=12)
        if case == 'valid':
            assert process.returncode == 0, (case, process.returncode, process.stderr)
            data = json.loads(result.read_text())
            assert data['readiness']['ready'] and data['bounded'], data
            assert pathlib.Path(data['directory']).resolve() == root / 'runtime'
            assert data['token'] == root.name and data['pid'] > 1
            assert stat.S_IMODE(result.stat().st_mode) == 0o600
        elif case == 'existing-result':
            assert process.returncode == 74 and result.read_text() == 'keep'
        else:
            assert process.returncode == 64 and not (root / 'runtime').exists()
        root.chmod(0o700)
        print('PASS: production storage helper', case)

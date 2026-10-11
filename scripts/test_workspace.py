"""Shared path guard for persistent GUI test workspaces."""
from pathlib import Path
import sys


def temporary_root(value):
    path = Path(value)
    if not path.is_absolute():
        raise ValueError('시험 폴더는 /private/tmp 아래의 절대 경로로 지정하세요.')
    root = path.resolve()
    if Path('/private/tmp') not in root.parents:
        raise ValueError('시험 앱의 파일 접근은 /private/tmp 아래에서만 수행합니다. '
                         'Documents의 기존 시험 폴더 대신 새 임시 폴더를 지정하세요.')
    return root


if __name__ == '__main__':
    try:
        print(temporary_root(sys.argv[1]))
    except (ValueError, IndexError) as error:
        sys.exit(str(error))

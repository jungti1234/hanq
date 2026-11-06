# 입력 감시와 첫 글자 복구 변경을 재현하는 방법

0.3.2-beta.1의 빌드 363부터 369까지, 직전 빌드에서 바뀐 소스·검사·명세를 순서대로 적용할 수 있다. 파일별 변경 목록, 패치의 SHA-256과 적용 후 Git 트리 ID는 [매니페스트](manifest.json)에 있다.

| 빌드 | 변경 |
| --- | --- |
| 363 | 유휴 감시의 재등록 판단을 보존하고 진단 기록 내보내기를 단계별로 처리한다. |
| 364 | 전환 중 예상한 편집 범위와 편집기가 보고한 범위의 변화를 구별한다. |
| 365 | 진단 저장 위치에 용량 한도를 설정하고 일반 재실행 뒤에도 같은 경로를 사용한다. |
| 366 | 선택 소스와 자판이 어긋나는 전환에서 첫 키를 보호하고 새로 입력된 범위를 확인한다. |
| 367 | 입력칸 밖에서 전환한 뒤 새로 입력된 글자와 기존 초안을 구분한다. |
| 368 | 입력 전후의 초안과 새 범위가 맞는지 대조하고 판정 근거를 기록한다. |
| 369 | 전환 직전에 확인한 창을 첫 키와 보정 시점에 다시 대조한다. |

## 적용과 검증

패치 폴더와 별개로, 빌드 362 소스의 깨끗한 임시 작업본을 준비한다. 그 작업본의 루트에서 아래 명령을 실행한다. 인덱스와 작업 파일에 적용되므로 전용 작업본을 사용한다. 처음의 기준 트리와 일곱 단계 각각의 결과 트리가 일치해야 다음 단계로 넘어간다.

```sh
python3 - /path/to/input-recovery-369 <<'PY'
import hashlib
import json
import subprocess
import sys
from pathlib import Path

folder = Path(sys.argv[1]).resolve()
series = json.loads((folder / "manifest.json").read_text())

def git(*args):
    return subprocess.check_output(["git", *args], text=True).strip()

def require(actual, expected, context):
    if actual != expected:
        raise SystemExit(f"{context}: expected {expected!r}, got {actual!r}")

require(git("status", "--porcelain"), "", "working tree")
require(git("write-tree"), series["baseTree"], "build 362")
for step in series["stages"]:
    patch = folder / step["file"]
    require(hashlib.sha256(patch.read_bytes()).hexdigest(), step["sha256"], patch.name)
    git("apply", "--check", "--index", "--unidiff-zero", str(patch))
    git("apply", "--index", "--unidiff-zero", str(patch))
    require(git("write-tree"), step["tree"], f"build {step['build']}")
    print(step["build"], step["tree"])
PY
```

빌드 369의 결과 트리는 `701401aeab99a59a800f0583e1f7479905a654a1`이다. 공개 361을 기반으로 독립 적용한 363~366 소스와 임시 시험 폴더 규칙은 [구현 브랜치](https://github.com/jungti1234/hanq/tree/codex/chat369-implementation)에서 검토할 수 있다. 두 경로는 적용을 시작하는 기준 트리가 다르다.

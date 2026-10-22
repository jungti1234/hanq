#!/bin/bash
# The running product handles guarded synthetic HID in this owned native app.
set -euo pipefail
cd "$(dirname "$0")/.."
record=${1:?사용법: test-long-document-input.sh record.json 새-결과-디렉터리}
output=${2:?새 결과 디렉터리가 필요합니다}
if [[ "${3:-}" == --control-no-product ]]; then
  process_status=0
  pgrep -x HanQ >/dev/null || process_status=$?
  [[ $process_status -eq 1 ]] || { echo '한Q가 실행 중이거나 조회에 실패했습니다.' >&2; exit 1; }
  export HANQ_LONG_NORMAL_ONLY=1
elif [[ $# -eq 2 ]]; then
  python3 scripts/prepare-app-test.py check "$record"
else
  echo '지원하지 않는 시험 옵션입니다.' >&2; exit 1
fi
[[ ! -e "$output" ]] || { echo '기존 결과를 덮어쓰지 않습니다.' >&2; exit 1; }
mkdir -p "$output"
output=$(cd "$output" && pwd)
source scripts/test-workspace.sh
stage=$(hanq_test_stage long-document)
printf '%s\n' "$stage" > "$output/stage.txt"
if [[ "${3:-}" != --control-no-product ]]; then
  cp "$record" "$stage/product.json"
  cp "$record" "$output/product.json"
fi
app="$stage/LongDocument.app"
cache=${HANQ_LONG_FIXTURE_CACHE:-}
if [[ -z "$cache" ]]; then
  cache="$stage/compiled-fixture"
  bash scripts/build-long-document-fixture.sh "$cache"
fi
python3 Tests/LongDocumentInput/fixture_cache.py copy "$cache" "$stage"
"$stage/source-control" "$stage" taek.in.hanq.long-document-fixture "$app/Contents/MacOS/LongDocument" > "$output/source-control.log" 2>&1 &
printf '%s\n' "$!" > "$output/source-control-pid.txt"
python3 Tests/LongDocumentInput/fixture_cache.py wait-ready "$stage"
"$stage/sender" "$stage" > "$output/sender.log" 2>&1 &
sender=$!
trap 'touch "$stage/quit"; kill "$sender" 2>/dev/null || true; wait "$sender" 2>/dev/null || true' EXIT
open -n "$app" --args "$stage"
status=0
python3 - "$stage" "$output" <<'PY' || status=$?
import pathlib,json,sys,time,shutil
stage,out=map(pathlib.Path,sys.argv[1:]);end=time.monotonic()+900
while time.monotonic()<end:
 if (stage/'results.json').exists():
  for n in ['results.json','ready.json','progress.json','product-exit.json','sender-guard.json','done.json','idle-start.json','idle-end.json','trial-start.json','trial-end.json','manual-precondition.json','source-control-ready.json','source-control-status.json','source-control-ended.json','cleanup.json']:
   if (stage/n).exists():shutil.copy2(stage/n,out/n)
  d=json.loads((out/'results.json').read_text());print(json.dumps(dict(passed=d['passed'],reason=d['reason'],cases=len(d['cases']),restored=d['restored']),ensure_ascii=False));sys.exit(0 if d['passed'] else 1)
 time.sleep(.1)
raise SystemExit('no complete result; not a pass')
PY
exit "$status"

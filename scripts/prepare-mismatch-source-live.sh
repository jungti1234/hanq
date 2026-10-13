#!/bin/bash
# Prepare one physical source interaction in an owned real AX editor.
# Final body equality must be checked with HanQ's recovery completion trace.
set -euo pipefail
cd "$(dirname "$0")/.."
record=${1:?권한 사전 체크 기록이 필요합니다}
output=${2:?새 결과 디렉터리가 필요합니다}
diagnostics=${3:?한Q의 --diagnose-input 진단 파일 경로가 필요합니다}
if pgrep -f '^/private/tmp/hanq-source-live[^/]*/SourceInteractionFixture.app/Contents/MacOS/SourceInteractionFixture' >/dev/null; then
  echo '기존 시험 창을 먼저 종료하고 설정 복원을 확인하세요.' >&2; exit 1
fi
python3 scripts/prepare-app-test.py check "$record"
[[ ! -e "$output" ]] || { echo '기존 결과를 덮어쓰지 않습니다.' >&2; exit 1; }
mkdir -p "$output"
output=$(cd "$output" && pwd)
source scripts/test-workspace.sh
ipc=$(hanq_test_stage source-live)
printf '%s\n' "$ipc" > "$output/ipc-path.txt"
if [[ -n "${4:-}" ]]; then cp "$4" "$ipc/prior.json"; fi
app="$ipc/SourceInteractionFixture.app"
mkdir -p "$app/Contents/MacOS"
cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?><!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd"><plist version="1.0"><dict><key>CFBundleExecutable</key><string>SourceInteractionFixture</string><key>CFBundleIdentifier</key><string>taek.in.hanq.source-interaction-fixture</string><key>CFBundleName</key><string>SourceInteractionFixture</string><key>NSPrincipalClass</key><string>NSApplication</string></dict></plist>
PLIST
swiftc -module-cache-path .build/hanq/module-cache Sources/HanQ/PhysicalLetterKeys.swift Sources/HanQ/JamoComposer.swift Sources/HanQ/KoreanKeyboardLayout.swift Sources/HanQ/InputSourceAccess.swift Sources/HanQ/RomanSwitchController.swift Tests/MismatchRecovery/Live/CapsTrial.swift Tests/MismatchRecovery/Live/TrialTrace.swift Tests/MismatchRecovery/Live/main.swift -o "$app/Contents/MacOS/SourceInteractionFixture"
codesign --force --sign - "$app"
build_number=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["app"]["build_number"])' "$record")
hanq_pid=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["main_pid"])' "$record")
args=("$ipc" "$diagnostics" "--hanq-build=$build_number" "--hanq-pid=$hanq_pid")
if [[ "${5:-}" != --single ]]; then args+=(--five); fi
if [[ "${5:-}" == --physical-three ]]; then args+=(--diagnostic-three --physical-three); fi
if [[ "${5:-}" == --smoke || "${5:-}" == --smoke-five || "${5:-}" == --menu-suite || "${5:-}" == --menu-single-suite || "${5:-}" == --self-check-first-key || "${5:-}" == --self-check-monitor || "${5:-}" == --self-check-retry || "${5:-}" == --self-check-retry-reset || "${5:-}" == --self-check-retry-pass || "${5:-}" == --self-check-retry-reprepare || "${5:-}" == --ime-only || "${5:-}" == --diagnostic-three ]]; then if [[ "$5" == --smoke ]]; then args+=(--smoke-five); else args+=("$5"); fi; fi
cp "$record" "$ipc/preflight.json"
cp scripts/prepare-app-test.py "$ipc/prepare-app-test.py"
cp Tests/MismatchRecovery/Live/retry.py "$ipc/retry.py"
hanq_app=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["app"]["path"])' "$record")
python3 - "$ipc" "$diagnostics" "$hanq_app" <<'PY'
import pathlib,subprocess,sys
root=pathlib.Path(sys.argv[1])
with (root/'retry.log').open('ab') as log:
    process=subprocess.Popen([sys.executable,str(root/'retry.py'),*sys.argv[1:]],
        cwd=root,stdin=subprocess.DEVNULL,stdout=log,stderr=subprocess.STDOUT,
        start_new_session=True,close_fds=True)
(root/'retry-helper.pid').write_text(str(process.pid)+'\n')
PY
open -n "$app" --args "${args[@]}"
echo "시험 창 준비: $ipc"
case "${5:-}" in
  --smoke|--smoke-five)
    echo '자동 첫 키 검사 창입니다. 소유 시험창 전용 probe.swift로 각 단계의 첫 키 한 쌍만 보냅니다. 물리 Caps Lock 검증은 별도입니다.'
    result=smoke-results.json ;;
  --physical-three)
    echo "두벌식 물리 RKS 진단입니다. 메뉴·Caps 전환 없이 세 글자 위치만 입력하세요."
    result=diagnostic-result.json ;;
  --diagnostic-three)
    echo "소유 창의 고정 RKS 자동 대조 검사입니다. 실제 메뉴·물리 키 통과로 세지 않습니다."
    result=diagnostic-result.json ;;
  --ime-only)
    echo 'IME 대조 검사 창입니다. 한Q를 통한 복구 검증이 아닙니다.'
    result=ime-results.json ;;
  --self-check-first-key|--self-check-monitor|--self-check-retry|--self-check-retry-reset|--self-check-retry-pass|--self-check-retry-reprepare)
    echo '시험 도구의 잘못된 첫 키·재시도 버튼 자동 검사입니다.'
    result=self-check.json ;;
  --menu-suite|--menu-single-suite)
    echo '시험창의 단계별 메뉴 전환 안내를 따르세요. 자동 검사와 실제 메뉴 선택을 구분해 기록합니다.'
    result=results.json ;;
  *)
    echo '안내된 첫 영문 키 위치 → Caps Lock 직접 한 번 → 영문 키 두 개. 입력 실수는 같은 단계 다시 시도로 새 기록을 만듭니다.'
    result=results.json ;;
esac
echo "결과 복사: cp '$ipc/$result' '$output/results.json'"
echo "시험 종료·설정 복원: touch '$ipc/stop'"

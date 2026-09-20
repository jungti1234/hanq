#!/bin/bash
# Run from a normal Terminal. sudo may ask for the Mac login password.
set -euo pipefail
cd "$(dirname "$0")/.."
samples="${1:-180}"
if ! [[ "$samples" =~ ^[1-9][0-9]*$ ]]; then
  echo 'Usage: bash scripts/measure-energy.sh [number-of-5-second-samples]' >&2
  exit 64
fi
output="$PWD/.build/hanq/performance/energy-$(date +%Y%m%d-%H%M%S).txt"
mkdir -p "$(dirname "$output")"
echo "한Q를 평소처럼 켜 둔 상태로 측정합니다. 설정과 권한을 변경하지 않습니다."
echo "측정 시간: $((samples * 5))초. 중단: Control-C. 기록: $output"
sudo /usr/bin/powermetrics --samplers tasks,cpu_power,battery \
  -i 5000 -n "$samples" --show-process-energy \
  --show-process-coalition --show-usage-summary > "$output"
echo "완료: $output"

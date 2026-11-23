#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
echo 'Legacy write budgets were retired; running storage migration compatibility tests.'
bash scripts/test-diagnostic-migration.sh

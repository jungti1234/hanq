#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
stage=$(mktemp -d "${TMPDIR:-/tmp}/hanq-versioning.XXXXXX")
trap 'rm -rf "$stage"' EXIT
mkdir -p "$stage/scripts"
cp scripts/build-app.sh "$stage/scripts/"
cp version.env "$stage/"
expected=$(bash scripts/build-app.sh --print-version)
actual=$(bash "$stage/scripts/build-app.sh" --print-version)
[[ "$actual" == "$expected" ]]
# An existing local app must not influence the release identity.
mkdir -p "$stage/build/HanQ.app/Contents"
printf 'not a plist; version lookup must not read this file\n' > "$stage/build/HanQ.app/Contents/Info.plist"
[[ $(bash "$stage/scripts/build-app.sh" --print-version) == "$expected" ]]
check_version() {
  local app=$1 build=$2 release=$3 expected_status=$4 status=0
  printf 'APP_VERSION=%s\nBUILD_NUMBER=%s\nRELEASE_VERSION=%s\n' "$app" "$build" "$release" > "$stage/version.env"
  bash "$stage/scripts/build-app.sh" --print-version >/dev/null 2>&1 || status=$?
  if [[ "$expected_status" == pass ]]; then [[ $status -eq 0 ]]; else [[ $status -ne 0 ]]; fi
}
check_version 0.1.0 71 0.1.0-beta.1 pass
check_version 1.0.0 73 1.0.0 pass
check_version 0.1.0 0 0.1.0-beta.1 fail
check_version 0.1.0 071 0.1.0-beta.1 fail
check_version 0.1.0 71 0.2.0-beta.1 fail
check_version 0.1.0 71 0x1x0-beta.1 fail
check_version 0.1.0 71 0.1.0-beta.0 fail
check_version 0.1 71 0.1 fail
echo 'PASS: clean-checkout version identity, local app independence, release format validation'

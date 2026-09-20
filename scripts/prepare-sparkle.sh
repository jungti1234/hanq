#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
# Pin the official release archive, including the tools and license.
version=2.10.0
sha256=c2bf58aa8387266ac179357b1415d6f2635f044da8be41042af32425dae6da0c
root="$PWD/.build/dependencies"
archive="$root/Sparkle-$version.tar.xz"
mkdir -p "$root"
if [[ ! -f "$archive" ]]; then
  download=$(mktemp "$root/download.XXXXXX")
  trap 'rm -f "$download"' EXIT
  curl --fail --location --proto '=https' --proto-redir '=https' --tlsv1.2 \
    "https://github.com/sparkle-project/Sparkle/releases/download/$version/Sparkle-$version.tar.xz" -o "$download"
  [[ "$(shasum -a 256 "$download" | cut -d ' ' -f 1)" == "$sha256" ]] || { echo 'Sparkle checksum mismatch' >&2; exit 1; }
  mv "$download" "$archive"
fi
[[ "$(shasum -a 256 "$archive" | cut -d ' ' -f 1)" == "$sha256" ]] || { echo 'Sparkle checksum mismatch' >&2; exit 1; }
if [[ ! -d "$root/sparkle-$version/Sparkle.framework" ]]; then
  stage=$(mktemp -d "$root/extract.XXXXXX")
  trap 'rm -rf "$stage"' EXIT
  tar -xf "$archive" -C "$stage"
  mv "$stage" "$root/sparkle-$version"
fi
printf '%s\n' "$root/sparkle-$version"

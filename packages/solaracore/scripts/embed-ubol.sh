#!/usr/bin/env bash
set -euo pipefail

source_dir="$1"
target_dir="$2"
here="$(cd "$(dirname "$0")" && pwd)"
if [ -z "${SOLARA_UBOL_LOCKED:-}" ]; then
  SOLARA_UBOL_LOCKED=1 exec lockf -k -t 120 "$(dirname "$source_dir")/.lock" "$0" "$@"
fi
node "$here/ubol-verify.mjs" "$source_dir"
mkdir -p "$target_dir"
rsync -a --delete "$source_dir/" "$target_dir/"

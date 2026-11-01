#!/usr/bin/env bash
set -euo pipefail

usage="usage: scripts/lib/sign-unsigned.sh [codesign options] <code>"
[ $# -gt 0 ] || { echo "$usage" >&2; exit 1; }
code="${!#}"
code_arguments=()
entitlements_source=""
code_options=""
while [ $# -gt 1 ]; do
  case "$1" in
    --entitlements) entitlements_source="$2"; shift 2 ;;
    --options) code_options="$2"; shift 2 ;;
    --preserve-metadata=*) shift ;;
    *) code_arguments+=("$1"); shift ;;
  esac
done
work="$(mktemp -d "${TMPDIR:-/tmp}/ac-sign-unsigned.XXXXXX")"
trap 'rm -rf "$work"' EXIT
if [ -n "$entitlements_source" ]; then
  cp "$entitlements_source" "$work/existing.entitlements"
else
  codesign -d --entitlements - --xml "$code" > "$work/existing.entitlements" 2>/dev/null || true
fi
python3 - "$work/existing.entitlements" "$work/unsigned.entitlements" <<'PY'
import plistlib
import sys
from pathlib import Path
stored = Path(sys.argv[1]).read_bytes()
entitlements = plistlib.loads(stored) if stored else {}
entitlements = {key: value for key, value in entitlements.items() if key not in ("keychain-access-groups", "com.apple.application-identifier", "com.apple.security.get-task-allow") and not key.startswith("com.apple.developer.")}
entitlements["com.apple.security.cs.disable-library-validation"] = True
with open(sys.argv[2], "wb") as destination:
    plistlib.dump(entitlements, destination)
PY
if [ -n "$code_options" ]; then
  code_options="$(printf '%s' "$code_options" | tr ',' '\n' | awk '$0 != "library" && NF' | paste -sd, -)"
  code_options="${code_options:-0}"
else
  existing_flags="$(codesign -dvv "$code" 2>&1 | sed -n 's/.* flags=\(0x[0-9a-fA-F]*\).*/\1/p')"
  code_options="$(( ${existing_flags:-0} & ~0x2000 ))"
fi
codesign --force --timestamp=none --sign - --preserve-metadata=identifier,runtime \
  --options "$code_options" --entitlements "$work/unsigned.entitlements" \
  ${code_arguments[@]+"${code_arguments[@]}"} "$code"

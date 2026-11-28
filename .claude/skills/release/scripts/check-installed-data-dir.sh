#!/usr/bin/env bash
set -euo pipefail

app="${1:?usage: check-installed-data-dir.sh <app>}"
info="$app/Contents/Info.plist"
bundle_id="$(plutil -extract CFBundleIdentifier raw "$info")"
product_dir="$(plutil -extract CrProductDirName raw "$info")"
if [[ -z "$bundle_id" || "$bundle_id" == *'$'* || "$bundle_id" == */* || "$product_dir" != "$bundle_id/Chromium" ]]; then
  echo "FAIL: $app: Chromium default '$product_dir' differs from installed path '$bundle_id/Chromium'" >&2
  exit 1
fi
printf 'PASS: %s uses the Chromium default %s\n' "$app" "$product_dir"

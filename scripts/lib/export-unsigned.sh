#!/usr/bin/env bash
set -euo pipefail

usage="usage: scripts/lib/export-unsigned.sh <archived Solara.app> <exported Solara.app> <entitlements>"
source_app="${1:?$usage}"
app="${2:?$usage}"
entitlements_template="${3:?$usage}"
die() { echo "error: $*" >&2; exit 1; }
here="$(cd "$(dirname "$0")" && pwd -P)"
[ -d "$source_app" ] || die "no $source_app"
work="$(mktemp -d "${TMPDIR:-/tmp}/ac-export-unsigned.XXXXXX")"
trap 'rm -rf "$work"' EXIT
python3 - "$entitlements_template" "$work/app.entitlements" <<'PY'
import plistlib
import sys
with open(sys.argv[1], "rb") as source:
    entitlements = plistlib.load(source)
entitlements = {key: value for key, value in entitlements.items() if key != "keychain-access-groups" and key != "com.apple.application-identifier" and not key.startswith("com.apple.developer.")}
with open(sys.argv[2], "wb") as destination:
    plistlib.dump(entitlements, destination)
PY
rm -rf "$app"
mkdir -p "$(dirname "$app")"
ditto "$source_app" "$app"
find "$app" -name embedded.provisionprofile -type f -delete
while IFS= read -r -d '' code; do
  if [ -f "$code" ]; then
    file -b "$code" | grep -q 'Mach-O' || continue
  fi
  case "$code" in
    */Chromium\ Framework.framework/Versions/*/Helpers/*"(Aperitif Renderer).app")
      "$here/sign-unsigned.sh" --options kill,runtime --entitlements "$here/../../packages/solaracore/scripts/signing/renderer.entitlements" "$code" ;;
    */Chromium\ Framework.framework/Versions/*/Helpers/*"(Aperitif GPU).app")
      "$here/sign-unsigned.sh" --options kill,runtime --entitlements "$here/../../packages/solaracore/scripts/signing/gpu.entitlements" "$code" ;;
    */Chromium\ Framework.framework/Versions/*/Helpers/*"(Aperitif"*").app")
      "$here/sign-unsigned.sh" --options kill,runtime "$code" ;;
    */Chromium\ Framework.framework/Versions/*/Helpers/*"Renderer).app")
      "$here/sign-unsigned.sh" --options restrict,kill,runtime --entitlements "$here/../../packages/solaracore/scripts/signing/renderer.entitlements" "$code" ;;
    */Chromium\ Framework.framework/Versions/*/Helpers/*"GPU).app")
      "$here/sign-unsigned.sh" --options restrict,kill,runtime --entitlements "$here/../../packages/solaracore/scripts/signing/gpu.entitlements" "$code" ;;
    */Chromium\ Framework.framework/Versions/*/Helpers/*.app | */Chromium\ Framework.framework/Versions/*/Helpers/chrome_crashpad_handler | */Chromium\ Framework.framework/Versions/*/Helpers/app_mode_loader | */Chromium\ Framework.framework/Versions/*/Helpers/web_app_shortcut_copier)
      "$here/sign-unsigned.sh" --options restrict,kill,runtime "$code" ;;
    *) "$here/sign-unsigned.sh" "$code" ;;
  esac
done < <(find "$app/Contents" -depth \
  \( -type d \( -name "*.xpc" -o -name "*.app" -o -name "*.appex" -o -name "*.framework" -o -name "*.plugin" \) \
  -o -type f \( -name "*.dylib" -o -perm -u+x \) \) -print0)
"$here/sign-unsigned.sh" --options runtime --entitlements "$work/app.entitlements" "$app"
codesign --verify --deep --strict "$app"
echo "exported $app with ad hoc signing and hardened runtime"

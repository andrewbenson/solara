#!/bin/bash
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
repo=$(cd "$here/../../.." && pwd)
name="Chromium Framework"
product=${AC_PRODUCT_NAME:-}

key_of() {
  printf '%s %s %s %s' "$product" "$1" "$(stat -f '%m %z' "$1/Versions/Current/$name")" \
    "$(find "$1/Versions/Current/" -type f -exec stat -f '%m' {} + | sort -n | tail -1)" | shasum -a 256 | cut -c1-16
}
if [[ "${1:-}" == --key ]]; then
  key_of "$2"
  exit 0
fi

built="${CHROMIUM_SRC:-$HOME/chromium-build/chromium_git/chromium/src}/out/Release_GN_arm64/$name.framework"
resolve_source() {
  if [[ -n "${SOLARACORE_FRAMEWORK:-}" ]]; then
    echo "$SOLARACORE_FRAMEWORK"
    return
  fi
  local fetched refusal wanted have= fetch_log
  fetch_log=$(mktemp -t solaracore-fetch) || return 1
  if fetched=$("$here/fetch-engine.sh" 2>"$fetch_log"); then
    cat "$fetch_log" >&2
    rm -f "$fetch_log"
    echo "$fetched"
    return
  fi
  refusal=$(grep -v '^ *$' "$fetch_log" | tail -1)
  rm -f "$fetch_log"
  wanted=$(sed -n 's/^export CHROMIUM_VERSION=//p' "$repo/engine/patches/build/env.sh")
  [[ -d "$built" ]] && have=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$built/Versions/Current/Resources/Info.plist" 2>/dev/null || true)
  if [[ -n "$wanted" && "${have:-}" == "$wanted" ]]; then
    echo "engine: using the engine built in $built (Chromium $have): no prebuilt engine fits this checkout (${refusal#error: })" >&2
    echo "$built"
    return
  fi
  local built_state="is missing"
  [[ -n "${have:-}" ]] && built_state="is Chromium $have, not $wanted"
  echo "error: no engine for this checkout: no prebuilt engine fits it (${refusal#error: }), and $built $built_state. Build the engine (scripts/agent/engine-build) or set SOLARACORE_FRAMEWORK" >&2
  return 1
}
if [[ "${1:-}" == --source ]]; then
  resolve_source
  exit
fi
dest=${SOLARACORE_STAGE_DIR:-$repo/apps/browser/build-solaracore/SolaraCoreFramework}
cache=${SOLARACORE_STAGE_CACHE:-$repo/apps/browser/build-solaracore/staged}

if [[ "${1:-}" == --publish ]]; then
  tmp=$2 key=$3
  if [[ -f "$cache/$key/.complete" ]]; then
    rm -rf "$tmp"
  else
    rm -rf "${cache:?}/$key"
    mv "$tmp" "$cache/$key"
  fi
  for old in "$cache"/*/; do
    old=${old%/}
    [[ -d "$old" ]] || continue
    [[ "${old##*/}" == "$key" ]] && continue
    [[ -n "$(find "$old" -maxdepth 0 -mmin -60)$(find "$old" -maxdepth 1 -name .used -mmin -60)" ]] || rm -rf "$old"
  done
  find "$cache" -mindepth 1 -maxdepth 1 -name '.tmp-*' -mmin +60 -exec rm -rf {} + 2>/dev/null || true
  exit 0
fi

src=$(resolve_source) || exit 1
[[ -n "$product" ]] || { echo "error: no AC_PRODUCT_NAME (run from the app's build, which sets it from the identity)" >&2; exit 1; }

keep_product_helpers() {
  local helpers=$1/Helpers helper suffix
  for suffix in "" " (Renderer)" " (GPU)" " (Alerts)"; do
    [[ -d "$helpers/$product Helper$suffix.app" ]] || {
      echo "error: the engine at $src has no \"$product Helper$suffix.app\": build it with this identity (scripts/agent/engine-build)" >&2
      return 1
    }
  done
  for helper in "$helpers"/*.app; do
    case "${helper##*/}" in
      "$product Helper.app" | "$product Helper ("*").app") ;;
      *) echo "staging: leaving out ${helper##*/}, not one of $product's helpers" >&2; rm -rf "$helper" || return 1 ;;
    esac
  done
}

[[ -d "$src" ]] || { echo "error: no SolaraCore framework at $src (engine/solaracore/apply.sh, then build chrome_framework)" >&2; exit 1; }
stamp="$dest/.stamp"

fill_cache() {
  local tmp="$cache/.tmp-$$" key fwv lib helper
  rm -rf "$tmp" && mkdir -p "$tmp" || return 1
  echo "staging $src" >&2
  local copy=(bash -c '
    set -e
    "$3" --key "$1" >"$2/.key"
    cp -cR "$1" "$2/"' _ "$src" "$tmp" "$here/${0##*/}")
  if [[ "$src" == "$HOME/chromium-build/"* ]]; then
    "$repo/scripts/agent/locked" chromium --wait 500 -- "${copy[@]}" >&2 || return 1
  else
    "${copy[@]}" >&2 || return 1
  fi
  key=$(cat "$tmp/.key") || return 1
  sign() { codesign --force --timestamp=none --sign - "$@"; }
  fwv=$(cd "$tmp/$name.framework/Versions/Current" && pwd -P) || return 1
  keep_product_helpers "$fwv" || return 1
  for lib in "$fwv"/Libraries/*.dylib; do
    if [[ -e "$lib" ]]; then sign "$lib" || return 1; fi
  done
  for helper in "$fwv"/Helpers/*.app "$fwv"/Helpers/chrome_crashpad_handler "$fwv"/Helpers/app_mode_loader "$fwv"/Helpers/web_app_shortcut_copier; do
    if [[ -e "$helper" ]]; then sign "$helper" || return 1; fi
  done
  sign "$tmp/$name.framework" || return 1
  touch "$tmp/.complete" "$tmp/.used" || return 1
  lockf -k -t 120 "$cache/.lock" "$0" --publish "$tmp" "$key" >&2 || return 1
  echo "$key"
}

key=$(key_of "$src")
if [[ -f "$stamp" && "$(cat "$stamp")" == "$key" && -d "$dest/$name.framework" ]]; then
  exit 0
fi
mkdir -p "$cache" "$dest"
for attempt in 1 2 3; do
  if [[ ! -f "$cache/$key/.complete" ]]; then
    key=$(fill_cache) || { echo "error: staging SolaraCore from $src failed" >&2; exit 1; }
  fi
  touch "$cache/$key/.used" 2>/dev/null || continue
  rm -rf "$dest/$name.framework.new"
  cp -cR "$cache/$key/$name.framework" "$dest/$name.framework.new" 2>/dev/null || continue
  rm -rf "$dest/$name.framework"
  mv "$dest/$name.framework.new" "$dest/$name.framework"
  echo "$key" >"$stamp"
  exit 0
done
echo "error: couldn't stage SolaraCore from $cache (it kept changing under this build)" >&2
exit 1

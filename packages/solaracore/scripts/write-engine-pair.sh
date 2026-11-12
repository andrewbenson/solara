#!/bin/bash
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
repo=$(cd "$here/../../.." && pwd)
app=$1
framework="$app/Contents/Frameworks/Chromium Framework.framework/Versions/Current/Chromium Framework"
resources="$app/Contents/Resources"
js_api=$(sed -n 's/^export const NATIVE_API_VERSION = \([0-9]*\);$/\1/p' "$repo/apps/browser/src/nativeApi.tsx")
app_api=$(sed -n 's/.*Constant("apiVersion") { () -> Int in \([0-9]*\) }.*/\1/p' "$repo/packages/shell/ios/AppModule.swift")
engine_api=$(sed -n 's/^#define AC_NOTIFICATIONS_NATIVE_API_VERSION \([0-9]*\)$/\1/p' "$repo/engine/chromium/src/chrome/browser/solara/public/ac_engine.h")
protocol=$(sed -n 's/^#define AC_NOTIFICATIONS_PROTOCOL_VERSION \([0-9]*\)$/\1/p' "$repo/engine/chromium/src/chrome/browser/solara/public/ac_engine.h")
[[ "$js_api" =~ ^[0-9]+$ && "$js_api" -ge 40 && "$app_api" == "$js_api" && "$engine_api" == 40 && "$protocol" == 2 ]] || {
  echo "error: the notification artifact requires matching app/JS APIs >= 40 and notification engine API 40 / protocol 2 sources" >&2
  exit 1
}
[[ -f "$framework" ]] || { echo "error: no embedded Chromium framework" >&2; exit 1; }
read_info() { plutil -extract "$1" raw "$app/Contents/Info.plist" 2>/dev/null || true; }
bundle=${2:-$(read_info CFBundleIdentifier)}
version=${3:-$(read_info CFBundleShortVersionString)}
build=${4:-$(read_info CFBundleVersion)}
[[ -n "$bundle" && -n "$version" && -n "$build" ]] || { echo "error: missing app identity for engine pair manifest" >&2; exit 1; }
pair="$resources/solara-engine-pair.plist"
if [[ "${5:-}" == finalize ]]; then
  [[ -f "$pair" ]] || { echo "error: archive has no app/engine pair manifest; rebuild the complete pair" >&2; exit 1; }
  for field in nativeApi notificationNativeApi notificationProtocol appBundleID appVersion appBuild; do
    case "$field" in
      nativeApi) expected=$js_api ;;
      notificationNativeApi) expected=$engine_api ;;
      notificationProtocol) expected=$protocol ;;
      appBundleID) expected=$bundle ;;
      appVersion) expected=$version ;;
      appBuild) expected=$build ;;
    esac
    [[ "$(plutil -extract "$field" raw "$pair")" == "$expected" ]] || { echo "error: archived $field does not match this app/engine pair" >&2; exit 1; }
  done
fi
framework_sha=$(shasum -a 256 "$framework" | awk '{print $1}')
mkdir -p "$resources"
temporary="$pair.tmp.$$"
trap 'rm -f "$temporary"' EXIT
plutil -create xml1 "$temporary"
plutil -insert appBundleID -string "$bundle" "$temporary"
plutil -insert appVersion -string "$version" "$temporary"
plutil -insert appBuild -string "$build" "$temporary"
plutil -insert nativeApi -integer "$js_api" "$temporary"
plutil -insert notificationNativeApi -integer "$engine_api" "$temporary"
plutil -insert notificationProtocol -integer "$protocol" "$temporary"
plutil -insert frameworkSHA256 -string "$framework_sha" "$temporary"
mv "$temporary" "$pair"

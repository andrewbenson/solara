#!/usr/bin/env bash
set -euo pipefail

usage="usage: scripts/release.sh <version> [--channel stable|nightly] [--unsigned] [--rc] [--phased <seconds>] [--phase build|sign|check]"
version="${1:?$usage}"
shift
rc=0
phased=""
channel=stable
phase=all
unsigned="${SOLARA_RELEASE_UNSIGNED:-0}"
while [ $# -gt 0 ]; do
  case "$1" in
    --unsigned) unsigned=1 ;;
    --rc) rc=1 ;;
    --channel)
      channel="${2:-}"
      shift
      case "$channel" in stable | nightly) ;; *) echo "error: --channel is stable or nightly, got '$channel'" >&2; exit 1 ;; esac
      ;;
    --phase)
      phase="${2:-}"
      shift
      case "$phase" in build | sign | check) ;; *) echo "error: --phase is build, sign or check, got '$phase'" >&2; exit 1 ;; esac
      ;;
    --phased)
      phased="${2:-}"
      shift
      case "$phased" in '' | *[!0-9]* | 0) echo "error: --phased takes whole seconds (86400 is a day), got '$phased'" >&2; exit 1 ;; esac
      ;;
    *) echo "error: unknown option $1 ($usage)" >&2; exit 1 ;;
  esac
  shift
done
case "$unsigned" in 0 | 1) ;; *) echo "error: SOLARA_RELEASE_UNSIGNED is 0 or 1" >&2; exit 1 ;; esac
export SOLARA_RELEASE_UNSIGNED="$unsigned"
[ "$rc" = 1 ] && [ -n "$phased" ] && { echo "error: a candidate is never published, so --phased doesn't apply to --rc" >&2; exit 1; }
if [ "$channel" = nightly ]; then
  [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+-nightly\.[0-9]+$ ]] \
    || { echo "error: a nightly's version is <next stable>-nightly.<n>, like 0.1.1-nightly.1 (got $version)" >&2; exit 1; }
else
  [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] \
    || { echo "error: a stable version is <major>.<minor>.<patch> (got $version; nightlies take --channel nightly)" >&2; exit 1; }
fi
if [ "$unsigned" = 1 ]; then
  [[ "$version" =~ ^0\.0\.[1-9][0-9]*(-nightly\.[0-9]+)?$ ]] \
    || { echo "error: unsigned releases are owner-only 0.0.x (got $version)" >&2; exit 1; }
else
  [[ ! "$version" =~ ^0\.0\. ]] \
    || { echo "error: 0.0.x must use SOLARA_RELEASE_UNSIGNED=1" >&2; exit 1; }
fi
root="$(cd "$(dirname "$0")/.." && pwd -P)"
app_dir="$root/apps/browser"
macos="$app_dir/macos"
solaracore="$root/packages/solaracore"
. "$root/scripts/identity.sh"
product_name="$(ac_identity AC_PRODUCT_NAME)"
team_id="$(ac_identity AC_TEAM_ID)"
bundle_id="$(ac_identity AC_BUNDLE_ID)"
repo="$(ac_identity AC_RELEASE_REPO)"
notes_page="$(ac_identity AC_NOTES_URL)"
public_ed_key="$(ac_identity AC_PUBLIC_ED_KEY)"
app_name="$(ac_identity FULL_PRODUCT_NAME)"
executable="$(ac_identity EXECUTABLE_NAME)"
for setting in product_name team_id bundle_id repo notes_page public_ed_key app_name executable; do
  [ -n "${!setting}" ] || { echo "error: the app's identity has no $setting (apps/browser/macos/Identity.xcconfig)" >&2; exit 1; }
done
case "$public_ed_key" in
  PLACEHOLDER* | *[!A-Za-z0-9+/=]*)
    echo "error: AC_PUBLIC_ED_KEY is '$public_ed_key', not a Sparkle public key: generate the key and paste its public half into Identity.xcconfig (docs/releasing.md)" >&2
    exit 1 ;;
esac
notary_profile="${NOTARY_PROFILE:-solara}"
[ "$unsigned" = 1 ] || { [ ! -f "$root/scripts/.notary.env" ] || . "$root/scripts/.notary.env"; }
notary_auth=()
if [ "$unsigned" = 0 ]; then
  if [ -n "${NOTARY_KEY:-}" ]; then
    notary_auth=(--key "$NOTARY_KEY" --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER")
  else
    notary_auth=(--keychain-profile "$notary_profile")
  fi
fi
"$root/scripts/verify-pods.sh"
sparkle="${SPARKLE_BIN:-$macos/Pods/Sparkle/bin}"
sparkle_key_file="${SPARKLE_KEY_FILE:-}"
if [ "$phase" = build ] || [ "$phase" = check ]; then
  :
elif [ -n "$sparkle_key_file" ]; then
  [ -s "$sparkle_key_file" ] || { echo "error: SPARKLE_KEY_FILE ($sparkle_key_file) is missing or empty" >&2; exit 1; }
elif [ -n "${SPARKLE_ACCOUNT:-}" ]; then
  sparkle_account="$SPARKLE_ACCOUNT"
else
  sparkle_account="$(ac_identity AC_SPARKLE_ACCOUNT)"
fi
[ "$phase" = build ] || [ "$phase" = check ] || [ -n "$sparkle_key_file" ] \
  || "$sparkle/generate_keys" --account "$sparkle_account" -p >/dev/null 2>&1 || {
  echo "error: no Sparkle EdDSA key in the login keychain under account $sparkle_account (SPARKLE_ACCOUNT; docs/releasing.md)" >&2
  exit 1
}
[ "$phase" = build ] || [ "$phase" = check ] || [ -n "$sparkle_key_file" ] \
  || "$sparkle/generate_keys" --account "$sparkle_account" -p 2>/dev/null | grep -qF -- "$public_ed_key" || {
  echo "error: the Sparkle key under account $sparkle_account isn't the one the app trusts (AC_PUBLIC_ED_KEY is $public_ed_key): updates signed with it would be refused" >&2
  exit 1
}
die() { echo "error: $*" >&2; exit 1; }
if [ "$rc" = 1 ]; then dist="$root/dist/$version-rc"; else dist="$root/dist/$version"; fi
[ "$rc" = 1 ] && [ -n "${RC_DIST:-}" ] && dist="$(cd "$root" && mkdir -p "$RC_DIST" && cd "$RC_DIST" && pwd)"
build="${RELEASE_BUILD_DIR:-$app_dir/build-release}"
archive="$dist/Solara.xcarchive"
app="$dist/export/$app_name"
zip="$dist/$product_name-$version.zip"
dmg="$dist/$product_name-$version.dmg"
chromium_src="${CHROMIUM_SRC:-$HOME/chromium-build/chromium_git/chromium/src}"
framework_src="${SOLARACORE_FRAMEWORK:-$chromium_src/out/Release_GN_arm64/Chromium Framework.framework}"
framework_engine="${SOLARACORE_FRAMEWORK_ENGINE:-}"
provisioning_profile="${RELEASE_PROVISIONING_PROFILE:-}"
read -r -a extra_build_settings <<<"${RELEASE_BUILD_SETTINGS:-}"
case "${RELEASE_BUILD_SETTINGS:-}" in
  *SOLARA_PROBES* | *-xcconfig* | *SWIFT_ACTIVE_COMPILATION_CONDITIONS* | *OTHER_SWIFT_FLAGS* | *GCC_PREPROCESSOR_DEFINITIONS*)
    echo "error: RELEASE_BUILD_SETTINGS may not set compile conditions or xcconfig files" >&2
    exit 1
    ;;
esac
build_input="${RELEASE_BUILD_INPUT:-}"
if [ "$phase" = sign ] && [ -n "$build_input" ]; then
  archive="$build_input/Solara.xcarchive"
fi
if [ "$phase" = sign ] || [ "$phase" = check ]; then
  framework_src="$archive/Products/Applications/$app_name/Contents/Frameworks/Chromium Framework.framework"
  [ "$phase" = check ] || [ -d "$archive" ] || die "no $archive: run --phase build first"
fi

verify_mode() {
  local details version_build
  codesign --verify --deep --strict "$app" || die "invalid app signature"
  details="$(codesign -dvv "$app" 2>&1)"
  version_build="$(plutil -extract CFBundleVersion raw "$app/Contents/Info.plist")"
  [[ "$version_build" =~ ^[0-9]+$ ]] && [ "$version_build" -gt 81 ] || die "CFBundleVersion must be strictly above 81"
  [ "$(plutil -extract CFBundleShortVersionString raw "$app/Contents/Info.plist")" = "$version" ] || die "the exported version differs from $version"
  if [ "$unsigned" = 1 ]; then
    [[ "$details" == *"Signature=adhoc"* && "$details" != *"Authority="* && "$details" == *"runtime"* ]] || die "unsigned release must be ad hoc signed with hardened runtime"
  else
    [[ "$details" == *"TeamIdentifier=$team_id"* && "$details" == *"Authority=Developer ID Application"* ]] || die "signed release must use Developer ID for $team_id"
  fi
}

free_port() {
  python3 -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])'
}

launch_hidden() {
  local target="$1" data="$2" port="$3" before p
  before="$(pgrep -f "^$target/Contents/MacOS/$executable" | sort || true)"
  open -g -n --env SOLARA_BACKGROUND=1 --env SOLARA_DATA_DIR="$data" --env SOLARA_REMOTE_DEBUGGING_PORT="$port" "$target"
  launched_pid=""
  for _ in $(seq 1 20); do
    for p in $(pgrep -f "^$target/Contents/MacOS/$executable\$" || true); do
      ps -E -ww -o command= -p "$p" 2>/dev/null | grep -qF "SOLARA_DATA_DIR=$data" && { launched_pid="$p"; break; }
    done
    [ -n "$launched_pid" ] || launched_pid="$(comm -13 <(echo "$before") <(pgrep -f "^$target/Contents/MacOS/$executable" | sort || true) | head -1)"
    [ -n "$launched_pid" ] && return 0
    sleep 1
  done
  die "$target didn't start"
}

stop_launched() {
  kill -TERM "$launched_pid"
  for _ in $(seq 1 30); do kill -0 "$launched_pid" 2>/dev/null || break; sleep 1; done
  kill -KILL "$launched_pid" 2>/dev/null || true
}

signed_launch_check() {
  local data port helpers
  data="$check_root/signed-data"
  mkdir -p "$data"
  port="$(free_port)"
  launch_hidden "$app" "$data" "$port"
  sleep 20
  kill -0 "$launched_pid" 2>/dev/null || die "the signed app quit within 20 s of launch"
  helpers="$(pgrep -f "^$app/Contents/Frameworks/Chromium Framework.framework/Versions/.*/Helpers/" | wc -l | tr -d ' ')"
  [ "$helpers" -ge 2 ] || { stop_launched; die "the signed app started $helpers engine helpers (expected at least 2)"; }
  if nc -z -G 2 127.0.0.1 "$port" 2>/dev/null; then stop_launched; die "the signed app opened the injected debugging port $port"; fi
  stop_launched
  codesign --verify --deep --strict "$app" || die "running the signed app changed its bundle"
  echo "    signed app: ran 20 s hidden with $helpers engine helpers, injected debugging port stayed closed"
}

launch_check() {
  echo "==> Launch check"
  check_root="$(cd "$(mktemp -d "${TMPDIR:-/tmp}/ac-release.XXXXXX")" && pwd -P)"
  check_data="$check_root/data"
  mkdir -p "$check_data"
  run_app="$app"
  if [ "$unsigned" = 0 ]; then
    signed_launch_check
    run_app="$check_root/test-copy/$app_name"
    "$root/scripts/lib/export-unsigned.sh" "$app" "$run_app" "$macos/Solara-macOS/Solara.entitlements" >/dev/null \
      || die "couldn't make the ad hoc test copy"
  fi
  check_port="$(free_port)"
  launch_hidden "$run_app" "$check_data" "$check_port"
  ubo_ok=0
  node "$root/scripts/lib/ubo-ready.mjs" "$check_port" 90 && ubo_ok=1
  sleep 5
  kill -0 "$launched_pid" 2>/dev/null || die "the app quit during the launch check"
  stop_launched
  codesign --verify --deep --strict "$run_app" || die "running the app changed its bundle"
  [ "$ubo_ok" = 1 ] || die "uBlock Origin wasn't ready and blocking in the exported app (90 s)"
  rm -rf "$check_root"
}
if [ "$phase" = check ]; then
  [ -d "$app" ] || die "no $app: run --phase sign first"
  "$root/scripts/agent/probe-scan" "$app"
  verify_mode
  launch_check
  verify_mode
  echo "Launch check passed: $app"
  exit 0
fi

pbx="$macos/Solara.xcodeproj/project.pbxproj"
project_version="$(sed -n 's/.*MARKETING_VERSION = "\{0,1\}\([^";]*\)"\{0,1\};/\1/p' "$pbx" | sort -u)"
project_build="$(sed -n 's/.*CURRENT_PROJECT_VERSION = \(.*\);/\1/p' "$pbx" | sort -u)"
version_settings=()
[[ "$project_build" =~ ^[0-9]+$ ]] || die "CURRENT_PROJECT_VERSION must be one consistent integer"
release_build="$project_build"
if [ "$rc" = 1 ]; then
  [ "$project_version" = "$version" ] || { release_build="$((project_build + 1))"; version_settings=(MARKETING_VERSION="$version" CURRENT_PROJECT_VERSION="$release_build"); }
elif [ "$project_version" != "$version" ]; then
  die "MARKETING_VERSION is '$project_version'. Set it to $version (and bump CURRENT_PROJECT_VERSION) first."
fi

[ "$release_build" -gt 81 ] || die "CURRENT_PROJECT_VERSION ($release_build) must be strictly above 81; 0.0.1 starts at 82 or higher"
if [ "$phase" = sign ]; then
  archived_info="$archive/Products/Applications/$app_name/Contents/Info.plist"
  [ "$(plutil -extract CFBundleShortVersionString raw "$archived_info")" = "$version" ] || die "the archive has the wrong version"
  [ "$(plutil -extract CFBundleVersion raw "$archived_info")" = "$release_build" ] || die "the archive has the wrong build number"
fi

notes="$root/docs/release-notes/$version.md"
if [ -f "$notes" ]; then
  frontmatter() { awk 'NR == 1 && $0 == "---" { inside = 1; next } inside && $0 == "---" { exit } inside' "$notes"; }
  notes_body() { awk 'NR == 1 && $0 == "---" { inside = 1; next } inside && $0 == "---" { inside = 0; next } !inside' "$notes" | sed '/./,$!d'; }
  meta="$(frontmatter)"
  headline="$(sed -n 's/^headline: *//p' <<< "$meta")"
  grep -Eq '^date: *[0-9]{4}-[0-9]{2}-[0-9]{2} *$' <<< "$meta" && [ -n "$headline" ] \
    || die "$notes needs 'date: YYYY-MM-DD' and 'headline:' frontmatter"
  notes_channel="$(sed -n 's/^channel: *//p' <<< "$meta" | tr -d ' ')"
  [ "${notes_channel:-stable}" = "$channel" ] \
    || die "$notes says 'channel: ${notes_channel:-stable}' but this is a $channel release (nightly notes carry 'channel: nightly')"
elif [ "$rc" = 1 ]; then
  headline="Release candidate $version"
  notes_channel="$channel"
  notes_body() { echo "A release candidate of $product_name $version. Not published."; }
else
  die "no release notes: write docs/release-notes/$version.md first"
fi

dirty="$(git -C "$root" status --porcelain -- apps/browser apps/cli packages engine scripts/dmg | grep -v ' apps/browser/build' || true)"
if [ -n "$dirty" ]; then
  [ "$rc" = 1 ] || { echo "$dirty" >&2; die "uncommitted changes under apps/browser, apps/cli, packages, engine or scripts/dmg (above)"; }
  echo "warning: the candidate includes uncommitted changes:" >&2
  echo "$dirty" >&2
fi

[ -d "$framework_src" ] || die "no SolaraCore framework at $framework_src (engine/solaracore/apply.sh, then build chrome_framework)"
[ "$phase" = sign ] || [[ " $(lipo -archs "$framework_src/Versions/Current/Chromium Framework" 2>/dev/null) " == *" arm64 "* ]] \
  || die "the SolaraCore framework at $framework_src has no arm64 slice"
if [ "$phase" = sign ]; then
  [ "$unsigned" = 1 ] || [ -n "$provisioning_profile" ] || die "--phase sign exports the ad hoc archive --phase build made: set RELEASE_PROVISIONING_PROFILE"
elif [ -n "$framework_engine" ]; then
  [ -n "${SOLARACORE_FRAMEWORK:-}" ] || die "SOLARACORE_FRAMEWORK_ENGINE names the engine tree a prebuilt SOLARACORE_FRAMEWORK was built from; set both or neither"
  [ "$framework_engine" = "$(git -C "$root" rev-parse HEAD:engine)" ] \
    || die "SOLARACORE_FRAMEWORK_ENGINE is $framework_engine but HEAD's engine tree is $(git -C "$root" rev-parse HEAD:engine): that framework wasn't built from this commit's engine"
fi
if [ "$phase" = all ] && [ -z "${SOLARACORE_FRAMEWORK:-}" ]; then
  "$root/scripts/lib/engine-fresh.sh" "$framework_src" "$chromium_src" || exit 1
fi

identity_name="Developer ID Application"
notarize=0
if [ "$phase" != build ] && [ "$unsigned" = 0 ]; then
  identity="$(security find-identity -v -p codesigning | awk -v n="$identity_name" -v t="($team_id)" 'index($0, n) && index($0, t) { print $2; exit }')"
  [ -n "$identity" ] || die "no $identity_name identity for team $team_id"
  if xcrun notarytool history "${notary_auth[@]}" >/dev/null 2>&1; then
    notarize=1
  elif [ "${ALLOW_UNNOTARIZED:-0}" = 1 ]; then
    echo "warning: no notarytool credentials; the build won't be notarized" >&2
  else
    echo "error: notarytool credentials are missing or invalid (scripts/.notary.env or the '$notary_profile' profile):" >&2
    xcrun notarytool history "${notary_auth[@]}" 2>&1 | head -2 >&2
    exit 1
  fi
fi

feed_base="${APPCAST_BASE:-https://github.com/$repo/releases/latest/download/appcast.xml}"
base_feed="$(mktemp "${TMPDIR:-/tmp}/ac-appcast.XXXXXX")"
trap 'rm -f "$base_feed"' EXIT
case "$feed_base" in
  none) : > "$base_feed" ;;
  http://* | https://*) curl -fsL "$feed_base" -o "$base_feed" || : > "$base_feed" ;;
  *) cp "$feed_base" "$base_feed" ;;
esac
if [ ! -s "$base_feed" ] && [ "$rc" = 0 ] && [ "$feed_base" != none ]; then
  die "couldn't read the published appcast ($feed_base): every release builds on it, or earlier versions and the other channel drop out of the feed"
fi
newest_listed="$(grep -o '<sparkle:version>[0-9]*<' "$base_feed" | tr -dc '0-9\n' | sort -n | tail -1 || true)"
[ -z "$newest_listed" ] || [ "$release_build" -gt "$newest_listed" ] \
  || die "the build number ($release_build) must be above every build in the feed, nightly or stable (newest: $newest_listed): bump CURRENT_PROJECT_VERSION"

build_cli() {
  echo "==> solara CLI"
  AC_PRODUCT_NAME="$product_name" AC_BUNDLE_ID="$bundle_id" AC_RELEASE_REPO="$repo" \
    "$root/apps/cli/scripts/build.sh" "$version" "$dist" >"$dist/cli-build.log" 2>&1 \
    || { tail -20 "$dist/cli-build.log" >&2; die "building the solara CLI failed ($dist/cli-build.log)"; }
}
cli_tarball="$dist/solara-cli-$version-macos-arm64.tar.gz"
if [ "$phase" != sign ]; then
  rm -rf "$dist"
  mkdir -p "$dist"
  {
    echo "version $version, build $release_build, $channel${version_settings:+ (${version_settings[*]})}"
    echo "commit $(git -C "$root" rev-parse HEAD)${dirty:+ + uncommitted changes}"
    echo "framework $(plutil -extract SCMRevision raw "$framework_src/Versions/Current/Resources/Info.plist" 2>/dev/null)"
    echo "framework built $(stat -f '%Sm' "$framework_src/Versions/Current/Chromium Framework")"
  } > "$dist/provenance.txt"

  echo "==> Content blocker"
  "$solaracore/scripts/ubo.sh"
  [ -f "$solaracore/vendor/ubo/ext/manifest.json" ] || die "uBlock Origin isn't installed ($solaracore/scripts/ubo.sh)"

  if [ "$unsigned" = 1 ] || [ -n "$provisioning_profile" ] || [ "$phase" = build ]; then
    archive_signing=(-xcconfig macos/AdHoc.xcconfig)
  else
    archive_signing=(-allowProvisioningUpdates)
  fi
  echo "==> Archive"
  (cd "$app_dir" && SOLARACORE_FRAMEWORK="$framework_src" "$root/scripts/agent/locked" pod --wait 1800 -- \
    "$root/scripts/verify-pods.sh" -- "$root/scripts/agent/locked" xcodebuild --wait 1800 -- xcodebuild -workspace macos/Solara.xcworkspace -scheme Solara-macOS \
    -configuration Release -destination 'generic/platform=macOS' ARCHS=arm64 SOLARACORE_STAGE_DIR="$build/SolaraCoreFramework" \
    ${version_settings[@]+"${version_settings[@]}"} AC_UPDATE_CHANNEL="$channel" \
    ${extra_build_settings[@]+"${extra_build_settings[@]}"} \
    -derivedDataPath "$build" -archivePath "$archive" "${archive_signing[@]}" archive) \
    > "$dist/archive.log" 2>&1 || {
    grep -E "error:|build commands failed" -A2 "$dist/archive.log" | grep -v MACOSX_DEPLOYMENT_TARGET | tail -20 >&2
    die "archive failed ($dist/archive.log)"
  }
fi
"$root/scripts/agent/probe-scan" "$archive/Products/Applications/$app_name"
if [ "$phase" = sign ] && [ -n "$build_input" ]; then
  rm -rf "$dist"
  mkdir -p "$dist"
fi
if [ "$phase" = build ]; then
  build_cli
  echo
  echo "Built $archive (signed ad hoc) and $(basename "$cli_tarball"); sign it with --phase sign."
  exit 0
fi

sign() {
  if [ "$unsigned" = 1 ]; then
    case "${*: -1}" in
      *.dmg) codesign --force --timestamp=none --sign - "$@" || die "ad hoc DMG signing failed" ;;
      *) "$root/scripts/lib/sign-unsigned.sh" "$@" || die "ad hoc signing failed" ;;
    esac
    return
  fi
  local attempt
  for attempt in 1 2 3 4 5; do
    codesign --force --timestamp --sign "$identity" "$@" && return 0
    echo "    signing failed (attempt $attempt), likely no timestamp from Apple; retrying" >&2
    sleep 5
  done
  die "couldn't sign ${*: -1}"
}
grants_browser_passkeys() {
  security cms -D -i "$1" 2>/dev/null \
    | plutil -extract 'Entitlements.com\.apple\.developer\.web-browser\.public-key-credential' raw -o - - 2>/dev/null | grep -qx true
}
if [ "$unsigned" = 1 ]; then
  echo "==> Export (ad hoc, owner only)"
  "$root/scripts/lib/export-unsigned.sh" "$archive/Products/Applications/$app_name" "$app" \
    "$macos/Solara-macOS/Solara.entitlements"
elif [ -n "$provisioning_profile" ]; then
  app_entitlements="$macos/Solara-macOS/Solara.entitlements"
  grants_browser_passkeys "$provisioning_profile" && app_entitlements="$macos/Solara-macOS/Solara-ICloudPasskeys.entitlements"
  echo "==> Export (Developer ID, $(basename "$provisioning_profile"), $(basename "$app_entitlements"))"
  "$root/scripts/lib/export-developer-id.sh" "$archive/Products/Applications/$app_name" "$app" "$provisioning_profile" \
    "$app_entitlements" "$identity" "$bundle_id" > "$dist/export.log" 2>&1 || { cat "$dist/export.log" >&2; exit 1; }
else
  echo "==> Export (Developer ID)"
  export_options="$dist/ExportOptions-DeveloperID.plist"
  cp "$macos/ExportOptions-DeveloperID.plist" "$export_options"
  plutil -replace teamID -string "$team_id" "$export_options"
  for attempt in 1 2 3 4 5 6; do
    rm -rf "$dist/export"
    xcodebuild -exportArchive -archivePath "$archive" -exportOptionsPlist "$export_options" \
      -exportPath "$dist/export" -allowProvisioningUpdates > "$dist/export.log" 2>&1 && break
    grep -q "A timestamp was expected" "$dist/export.log" && [ "$attempt" -lt 6 ] \
      || { cat "$dist/export.log" >&2; exit 1; }
    echo "    no timestamp from Apple (attempt $attempt), exporting again"
    sleep 10
  done
fi
"$root/scripts/agent/probe-scan" "$app"
[ "$(lipo -archs "$app/Contents/MacOS/$executable")" = arm64 ] || die "the app's executable is $(lipo -archs "$app/Contents/MacOS/$executable"), not arm64"

if [ "$phase" = all ]; then
  build_cli
else
  if [ -n "$build_input" ]; then
    for file in provenance.txt "$(basename "$cli_tarball")" "$(basename "$cli_tarball").sha256"; do
      [ -f "$build_input/$file" ] && [ ! -L "$build_input/$file" ] || die "no $file in $build_input"
      cp "$build_input/$file" "$dist/$file"
    done
  fi
  [ -f "$cli_tarball.sha256" ] || die "no $cli_tarball.sha256 from --phase build"
fi
awk '{ print $1 }' "$cli_tarball.sha256" >"$app/Contents/Resources/solara-cli.sha256"

echo "==> Licenses"
licenses="$app/Contents/Resources/Licenses"
mkdir -p "$licenses"
cp "$root"/LICENSE* "$root/NOTICE" "$licenses/"

echo "==> Sign Chrome's framework"
entitlements_dir="$solaracore/scripts/signing"
fw="$app/Contents/Frameworks/Chromium Framework.framework"
fwv="$(cd "$fw/Versions/Current" && pwd -P)" || die "no Chromium Framework.framework in the export"
"$solaracore/scripts/strip-engine.sh" "$app" "$dist/symbols"
unpruned_engine="$dist/engine-unpruned"
rm -rf "$unpruned_engine" && mkdir -p "$unpruned_engine" && cp -cR "$fw" "$unpruned_engine/"
"$solaracore/scripts/prune-bundle.sh" "$app"
for lib in "$fwv"/Libraries/*.dylib; do sign "$lib"; done
for helper in "$fwv"/Helpers/*.app; do
  case "$(basename "$helper")" in
    *"Renderer).app") sign --options restrict,kill,runtime --entitlements "$entitlements_dir/renderer.entitlements" "$helper" ;;
    *"GPU).app") sign --options restrict,kill,runtime --entitlements "$entitlements_dir/gpu.entitlements" "$helper" ;;
    *) sign --options restrict,library,kill,runtime "$helper" ;;
  esac
done
sign --options restrict,library,kill,runtime "$fwv/Helpers/chrome_crashpad_handler"
sign --options restrict,library,kill,runtime "$fwv/Helpers/app_mode_loader"
[ -e "$fwv/Helpers/web_app_shortcut_copier" ] && sign --options restrict,library,kill,runtime \
  --identifier "$bundle_id.web_app_shortcut_copier" "$fwv/Helpers/web_app_shortcut_copier"
sign "$fw"
[ -d "$app/Contents/Frameworks/hermes.framework" ] \
  && sign --preserve-metadata=identifier,entitlements,flags,runtime "$app/Contents/Frameworks/hermes.framework"
if [ "$unsigned" = 1 ]; then
  sign --preserve-metadata=entitlements,flags,runtime "$app"
else
  sign --preserve-metadata=entitlements,requirements,flags,runtime "$app"
fi

echo "==> Verify"
codesign --verify --deep --strict "$app"
[ -d "$archive/dSYMs/$app_name.dSYM" ] || die "the archive has no $app_name.dSYM"
entitlements() { codesign -d --entitlements - --xml "$1" 2>/dev/null; }
info() { plutil -extract "$1" raw "$app/Contents/Info.plist" 2>/dev/null; }
[ "$(info CFBundleIdentifier)" = "$bundle_id" ] || die "bundle id is $(info CFBundleIdentifier), not $bundle_id"
[ "$(info CFBundleName)" = "$product_name" ] || die "CFBundleName is $(info CFBundleName), not $product_name"
[ "$(info CFBundleDisplayName)" = "$product_name" ] || die "CFBundleDisplayName is $(info CFBundleDisplayName), not $product_name"
[ "$(info SUPublicEDKey)" = "$public_ed_key" ] || die "SUPublicEDKey is $(info SUPublicEDKey), not $public_ed_key"
[ "$(info CFBundleExecutable)" = "$executable" ] || die "executable is $(info CFBundleExecutable), not $executable"
[ "$(info CFBundleShortVersionString)" = "$version" ] || die "CFBundleShortVersionString is $(info CFBundleShortVersionString)"
[ "$(info CFBundleVersion)" = "$release_build" ] || die "CFBundleVersion is $(info CFBundleVersion), not $release_build"
[ "$(info ACUpdateChannel)" = "$channel" ] || die "ACUpdateChannel is '$(info ACUpdateChannel)', not $channel"
for key in SUFeedURL SUPublicEDKey NSDockTilePlugIn NSCameraUsageDescription NSMicrophoneUsageDescription \
  NSBluetoothAlwaysUsageDescription NSLocationUsageDescription NSLocalNetworkUsageDescription; do
  [ -n "$(info "$key")" ] || die "Info.plist has no $key"
done
[ -d "$app/Contents/Frameworks/Sparkle.framework" ] || die "no Sparkle.framework"
for helper in "$fwv"/Helpers/*.app; do
  case "$(basename "$helper")" in
    "$product_name Helper.app" | "$product_name Helper ("*").app") ;;
    *) die "the framework carries $(basename "$helper"), not one of $product_name's helpers" ;;
  esac
done
[ -d "$app/Contents/PlugIns/$(info NSDockTilePlugIn)" ] || die "no dock tile plug-in"
[ "$unsigned" = 1 ] || [ -f "$app/Contents/embedded.provisionprofile" ] || die "no Developer ID provisioning profile (keychain groups need it)"
[ -f "$app/Contents/Resources/Extensions/ublock/manifest.json" ] || die "no uBlock Origin in the app"
for file in "$root"/LICENSE* "$root/NOTICE"; do
  cmp -s "$file" "$app/Contents/Resources/Licenses/$(basename "$file")" || die "the app lacks $(basename "$file") in Contents/Resources/Licenses"
done
app_ents="$(entitlements "$app")"
if [ "$unsigned" = 1 ]; then
  [[ "$app_ents" == *com.apple.security.cs.disable-library-validation* ]] || die "the ad hoc app lacks the library-validation exception"
  [[ "$app_ents" != *keychain-access-groups* && "$app_ents" != *com.apple.developer.* && "$app_ents" != *com.apple.application-identifier* ]] || die "the ad hoc app has profile-restricted entitlements"
else
  designated="$(codesign -d -r- "$app" 2>&1 | sed -n 's/^designated => //p')"
  [[ "$designated" == *"identifier \"$bundle_id\""* && ( "$designated" == *"subject.OU] = $team_id"* || "$designated" == *"subject.OU] = \"$team_id\""* ) ]] \
    || die "designated requirement: $designated"
  for group in webauthn unexportable-keys secure-payment-confirmation; do
    [[ "$app_ents" == *"$team_id.$bundle_id.$group"* ]] || die "the app lacks the keychain group …$group"
  done
  if grants_browser_passkeys "$app/Contents/embedded.provisionprofile"; then
    [[ "$app_ents" == *web-browser.public-key-credential* ]] || die "the profile grants browser passkeys but the app isn't signed with them"
  else
    [[ "$app_ents" != *web-browser.public-key-credential* ]] || die "the app is signed with com.apple.developer.web-browser.public-key-credential, which its profile doesn't grant"
  fi
fi
for helper in "$fwv"/Helpers/*"Renderer).app" "$fwv"/Helpers/*"GPU).app"; do
  [[ "$(entitlements "$helper")" == *cs.allow-jit* ]] || die "$(basename "$helper") lost allow-jit"
done
while IFS= read -r -d '' code; do
  details="$(codesign -dvv "$code" 2>&1)"
  if [ "$unsigned" = 1 ]; then
    [[ "$details" == *"Signature=adhoc"* && "$details" != *"Authority="* ]] || die "$code is not ad hoc signed"
    code_ents="$(entitlements "$code")"
    [[ "$code_ents" != *keychain-access-groups* && "$code_ents" != *com.apple.developer.* && "$code_ents" != *com.apple.application-identifier* ]] || die "$code has profile-restricted entitlements"
  else
    [[ "$details" == *"TeamIdentifier=$team_id"* && "$details" == *"Authority=Developer ID Application"* \
      && "$details" == *"Timestamp="* ]] || die "$code isn't Developer ID-signed with a timestamp"
  fi
  [[ "$(entitlements "$code")" != *get-task-allow* ]] || die "$code has get-task-allow"
done < <(find "$app" \( -name "*.app" -o -name "*.framework" -o -name "*.dylib" -o -name "*.xpc" -o -name "*.plugin" \
  -o -path "*/Helpers/*" -type f -perm -u+x -o -path "*/MacOS/*" -type f \) -print0)

verify_mode

engine_tree="$(git -C "$root" rev-parse HEAD:engine)"
engine_archive="$dist/SolaraCore-${engine_tree:0:12}.tar.xz"
engine_source="$dist/SolaraCore-${engine_tree:0:12}-source.tar.xz"
engine_release="$(awk -v t="$engine_tree" '$1 == t { print $2; exit }' "$solaracore/prebuilt-engines.tsv")"
helium_engine=""
LC_ALL=C grep -q -a -F helium.services.enabled "$framework_src/Versions/Current/Chromium Framework" && helium_engine=1
engine_pack=""
if { [ "$phase" = all ] || [ "$phase" = sign ]; } && [ "$rc" = 0 ] && { [ -z "${SOLARACORE_FRAMEWORK:-}" ] || [ -n "$framework_engine" ]; } && [ -z "$engine_release" ]; then
  engine_release="$version"
  echo "==> Pack the engine (background)"
  (
    set -e
    [ -z "$helium_engine" ] || "$root/scripts/engine-source.sh" "$version" "$engine_source"
    if command -v xz >/dev/null; then
      tar --no-mac-metadata -cf - -C "$unpruned_engine" "Chromium Framework.framework" | xz -T0 -9 >"$engine_archive"
    else
      tar --no-mac-metadata -cJf "$engine_archive" -C "$unpruned_engine" "Chromium Framework.framework"
    fi
    rm -rf "$unpruned_engine"
    printf '%s\t%s\t%s\n' "$engine_tree" "$version" "$(shasum -a 256 "$engine_archive" | awk '{ print $1 }')" \
      >"$dist/prebuilt-engine.tsv"
  ) >"$dist/engine-pack.log" 2>&1 &
  engine_pack=$!
else
  rm -rf "$unpruned_engine"
fi
[ -z "$helium_engine" ] || [ "$rc" = 1 ] || [ -n "$engine_release" ] \
  || die "no published release carries this engine ($engine_tree) and its source: build it from the Chromium tree, without SOLARACORE_FRAMEWORK, or name the engine tree it was built from in SOLARACORE_FRAMEWORK_ENGINE"

[ "$phase" = sign ] || launch_check
verify_mode

notarize_file() {
  echo "Notarizing $(basename "$1")"
  xcrun notarytool submit "$1" "${notary_auth[@]}" --wait --timeout 1h | tee "$dist/notary-$(basename "$1").log"
  grep -q "status: Accepted" "$dist/notary-$(basename "$1").log" || die "notarization failed"
}
if [ "$notarize" = 1 ]; then
  echo "==> Notarize app"
  ditto -c -k --keepParent "$app" "$dist/notarize.zip"
  notarize_file "$dist/notarize.zip"
  rm "$dist/notarize.zip"
  xcrun stapler staple "$app"
fi

echo "==> Package"
update_dir="$dist/update"
rm -rf "$update_dir" && mkdir -p "$update_dir"
ditto "$app" "$update_dir/$product_name.app"
ditto -c -k --keepParent "$update_dir/$product_name.app" "$zip"
rm -rf "$update_dir"
staging="$dist/dmg"
mkdir -p "$staging"
ditto "$app" "$staging/$product_name.app"
ln -s /Applications "$staging/Applications"
cp "$root/scripts/dmg/background.tiff" "$staging/.background.tiff"
dmg_layout="$root/scripts/dmg/DS_Store-$product_name"
[ -f "$dmg_layout" ] || die "missing DMG layout $dmg_layout; generate it with scripts/dmg/layout.sh $product_name"
cp "$dmg_layout" "$staging/.DS_Store"
cp "$app/Contents/Resources/$(info CFBundleIconName || echo AppIcon).icns" "$staging/.VolumeIcon.icns"
mkdir -p "$staging/.fseventsd" && touch "$staging/.fseventsd/no_log"
dmg_rw="$dist/dmg-rw.dmg" dmg_mnt="$dist/dmg-mnt"
rm -rf "$dmg_rw" "$dmg_mnt" && mkdir "$dmg_mnt"
hdiutil create -volname "$product_name" -srcfolder "$staging" -format UDRW -ov "$dmg_rw" >/dev/null
rm -rf "$staging"
hdiutil attach "$dmg_rw" -nobrowse -noautoopen -noverify -mountpoint "$dmg_mnt" >/dev/null
SetFile -a C "$dmg_mnt" || { hdiutil detach "$dmg_mnt" -force >/dev/null; die "couldn't flag the volume's icon"; }
for attempt in 1 2 3 4 5; do
  hdiutil detach "$dmg_mnt" >/dev/null 2>&1 && break
  [ "$attempt" = 5 ] && { hdiutil detach "$dmg_mnt" -force >/dev/null || die "couldn't eject $dmg_mnt"; }
  sleep 2
done
dmg_chunks=(-imagekey udif-chunk-size=8192)
[ "${SOLARA_DMG_CHUNK:-on}" = off ] && dmg_chunks=()
hdiutil convert "$dmg_rw" -format ULMO ${dmg_chunks[@]+"${dmg_chunks[@]}"} -ov -o "$dmg" >/dev/null
rm -rf "$dmg_rw" "$dmg_mnt"
sign "$dmg"
if [ "$notarize" = 1 ]; then
  notarize_file "$dmg"
  xcrun stapler staple "$dmg"
fi

echo "==> Release notes"
if [ "$channel" = nightly ]; then
  updates_line="A nightly: every fix the day it lands, tested less than a stable release. It updates to newer nightlies and stables ($product_name › Check for Updates…); Settings › General › Update channel switches back to Stable, which never downgrades. Every release's notes: $notes_page"
else
  updates_line="Earlier versions update automatically ($product_name › Check for Updates…). Every release's notes: $notes_page"
fi
if [ "$unsigned" = 1 ]; then
  install_line="Apple Silicon, macOS 26 or later. Owner-only 0.0.x: ad hoc signed, without Developer ID or notarization. Sparkle updates are authenticated by the Solara EdDSA key. macOS may require Privacy & Security › Open Anyway for the first launch."
elif [ "$notarize" = 1 ]; then
  install_line="Apple Silicon, macOS 14 or later. Signed with Developer ID and notarized by Apple: download, drag it to Applications, open it."
else
  install_line="Apple Silicon, macOS 14 or later. Signed with Developer ID but not notarized: on first launch macOS refuses to open it. Click Done, then System Settings › Privacy & Security › Open Anyway. Or run \`xattr -dr com.apple.quarantine /Applications/$product_name.app\`."
fi
case "$engine_release" in engine-*) engine_tag="$engine_release" ;; *) engine_tag="v$engine_release" ;; esac
source_line="This build's source, with the engine's patches and build scripts: https://github.com/$repo/tree/v$version (LICENSE and NOTICE there cover the licenses)."
engine_repo="$repo"
[ -n "$engine_pack" ] || engine_repo="${SOLARACORE_PREBUILT_REPO:-$repo}"
[ -n "$helium_engine" ] && [ -n "$engine_release" ] && source_line="$source_line The engine's Helium and uBlock sources as built, and where Chromium's is: https://github.com/$engine_repo/releases/download/$engine_tag/$(basename "$engine_source")"
{
  notes_body
  cat <<EOF

## Install

$install_line

$updates_line

## Source

$source_line
EOF
} > "$dist/release-notes.md"

echo "==> Appcast"
updates="$dist/updates"
mkdir -p "$updates"
cp "$zip" "$updates/"
{ printf '**%s**\n\n' "$headline"; notes_body; } > "$updates/$(basename "$zip" .zip).md"
[ -s "$base_feed" ] && cp "$base_feed" "$updates/appcast.xml"
if [ -n "$sparkle_key_file" ]; then
  key="$sparkle_key_file"
else
  "$root/scripts/verify-pods.sh"
  key="$(mktemp -d)/sparkle-key"
  trap 'rm -rf "$(dirname "$key")" "$base_feed"' EXIT
  "$sparkle/generate_keys" --account "$sparkle_account" -x "$key" >/dev/null 2>&1 || die "could not export the Sparkle EdDSA key"
fi
swiftc -O "$root/.claude/skills/release/scripts/ed25519.swift" -o "$dist/ed25519-check" 2>/dev/null
dmg_signature="$("$sparkle/sign_update" --ed-key-file "$key" "$dmg" 2>/dev/null \
  | sed -n 's/^sparkle:edSignature="\([A-Za-z0-9+/=]*\)".*/\1/p')" || die "Sparkle could not sign the DMG (key unreadable or invalid)"
[ -n "$dmg_signature" ] && "$dist/ed25519-check" verify "$dmg" "$dmg_signature" "$public_ed_key" || die "DMG EdDSA signature does not match AC_PUBLIC_ED_KEY"
printf '%s\n' "$dmg_signature" > "$dmg.edSignature"
phased_args=()
[ -n "$phased" ] && phased_args=(--phased-rollout-interval "$phased")
[ "$channel" = nightly ] && phased_args+=(--channel nightly)
"$sparkle/generate_appcast" --ed-key-file "$key" ${phased_args[@]+"${phased_args[@]}"} \
  --download-url-prefix "https://github.com/$repo/releases/download/v$version/" \
  --embed-release-notes --full-release-notes-url "$notes_page" \
  --link "https://github.com/$repo" -o "$updates/appcast.xml" "$updates" >/dev/null 2>&1 \
  || die "Sparkle appcast generation failed (key unreadable or invalid)"
mv "$updates/appcast.xml" "$dist/appcast.xml"
zip_signature="$(python3 - "$dist/appcast.xml" "$release_build" <<'PY'
import sys
import xml.etree.ElementTree as ET
namespace = "{http://www.andymatuschak.org/xml-namespaces/sparkle}"
items = [item for item in ET.parse(sys.argv[1]).findall("./channel/item") if item.findtext(namespace + "version") == sys.argv[2]]
if len(items) != 1:
    raise SystemExit("appcast must contain exactly one matching build")
print(items[0].find("enclosure").get(namespace + "edSignature", ""))
PY
)"
[ -n "$zip_signature" ] && "$dist/ed25519-check" verify "$zip" "$zip_signature" "$public_ed_key" || die "ZIP EdDSA signature does not match AC_PUBLIC_ED_KEY"
rm "$dist/ed25519-check"
grep -q "<sparkle:shortVersionString>$version<" "$dist/appcast.xml" || die "appcast.xml has no item for $version"
minimum_system="$(info LSMinimumSystemVersion)"
[ "$minimum_system" = 26.0 ] || die "the app's LSMinimumSystemVersion is $minimum_system; Solara requires macOS 26.0"
grep -q "<sparkle:minimumSystemVersion>$minimum_system<" "$dist/appcast.xml" || die "appcast.xml doesn't state minimumSystemVersion $minimum_system"
rm -rf "$updates"

engine_files=()
if [ -n "$engine_pack" ]; then
  wait "$engine_pack" || { cat "$dist/engine-pack.log" >&2; die "packing the engine failed ($dist/engine-pack.log)"; }
  rm -f "$dist/engine-pack.log"
  engine_files=("$engine_archive" "$dist/prebuilt-engine.tsv")
  [ -z "$helium_engine" ] || engine_files+=("$engine_source")
fi

echo
[ "$notarize" = 1 ] && echo "Notarized and stapled." || echo "NOT notarized."
[ -n "$engine_pack" ] && echo "New engine: publish $(basename "$engine_archive")${helium_engine:+ and $(basename "$engine_source")} with the release, then add prebuilt-engine.tsv's line to packages/solaracore/prebuilt-engines.tsv."
[ "$rc" = 1 ] && echo "Release candidate: never publish dist/$version-rc."
[ "$channel" = nightly ] && [ "$rc" = 0 ] && echo "Nightly: publish it with .claude/skills/release/scripts/publish.sh $version (a prerelease; the feed follows)."
[ "$phase" = sign ] && echo "Not launched yet: remove the signing keys, then run the launch check (--phase check)."
[ -n "$phased" ] && echo "Phased rollout: $phased s between steps (the appcast item has phasedRolloutInterval; the whole release takes $((phased * 7)) s)."
du -sh "$app" "$dmg" "$zip" "$cli_tarball" "$dist/appcast.xml" "$dist/release-notes.md" ${engine_files[@]+"${engine_files[@]}"}

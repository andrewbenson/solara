#!/usr/bin/env bash
set -euo pipefail

usage="usage: publish.sh <version> [--dry-run] [--break-lock]"
version="${1:?$usage}"
shift
dry=0
break_lock=0
for arg in "$@"; do
  case "$arg" in
    --dry-run) dry=1 ;;
    --break-lock) break_lock=1 ;;
    *) echo "error: unknown option $arg ($usage)" >&2; exit 1 ;;
  esac
done
here="$(cd "$(dirname "$0")" && pwd)"
root="$(git -C "$here" rev-parse --show-toplevel)"
. "$here/verify-release.sh"
. "$root/scripts/identity.sh"
repo="$(ac_identity AC_RELEASE_REPO)"
[ -n "$repo" ] || { echo "error: the app's identity has no AC_RELEASE_REPO" >&2; exit 1; }
product="$(ac_identity AC_PRODUCT_NAME)"
[ -n "$product" ] || { echo "error: the app's identity has no AC_PRODUCT_NAME" >&2; exit 1; }
notes_page="$(ac_identity AC_NOTES_URL)"
dist="${RELEASE_DIST:-$root/dist/$version}"
latest_url="https://github.com/$repo/releases/latest/download"
nightly_url="https://github.com/$repo/releases/download/nightly"
die() { echo "error: $*" >&2; exit 1; }
run() {
  echo "+ $*"
  [ "$dry" = 1 ] || "$@"
}

if [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+-nightly\.[0-9]+$ ]]; then
  channel=nightly
elif [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  channel=stable
else
  die "$version is neither a stable (<major>.<minor>.<patch>) nor a nightly (<next stable>-nightly.<n>) version"
fi
if [ "${SOLARA_RELEASE_UNSIGNED:-0}" = 1 ]; then
  [[ "$version" =~ ^0\.0\.[1-9][0-9]*(-nightly\.[0-9]+)?$ ]] || die "unsigned releases must be 0.0.x"
else
  [[ ! "$version" =~ ^0\.0\.[0-9]+(-nightly\.[0-9]+)?$ ]] || die "0.0.x releases require SOLARA_RELEASE_UNSIGNED=1"
fi
dmg="$dist/$product-$version.dmg"
zip="$dist/$product-$version.zip"
nightly_dmg="$product-Nightly.dmg"
feed="$dist/appcast.xml"
cli="$dist/solara-cli-$version-macos-arm64.tar.gz"

assets=()
for file in "$dmg" "$zip" "$feed" "$cli" "$cli.sha256"; do
  [ -f "$file" ] || die "no $file (scripts/release.sh $version --channel $channel first)"
  assets+=("$file")
done
item="$(awk -v v="$version" '/<item>/ { buf = "" } { buf = buf $0 "\n" } /<\/item>/ && buf ~ ("shortVersionString>" v "<") { print buf; exit }' "$feed")"
[ -n "$item" ] || die "$feed has no item for $version"
if [ "$channel" = nightly ]; then
  grep -q '<sparkle:channel>nightly</sparkle:channel>' <<<"$item" || die "$version's item in $feed isn't on the nightly channel"
else
  ! grep -q '<sparkle:channel>' <<<"$item" || die "$version's item in $feed is on a channel, so stable copies would skip it"
fi
[ -f "$dist/release-notes.md" ] || die "no $dist/release-notes.md"
for archive in "$dist"/SolaraCore-*.tar.xz; do [ -f "$archive" ] && assets+=("$archive"); done
. "$here/publish-lock.sh"

work="$(mktemp -d "${TMPDIR:-/tmp}/ac-publish.XXXXXX")"
trap 'release_lock; rm -rf "$work"' EXIT
trap 'exit 130' INT TERM HUP
if [ "${SOLARA_RELEASE_UNSIGNED:-0}" = 1 ]; then
  app="$dist/export/$product.app"
  release_verify_ad_hoc "$app" && release_verify_ad_hoc "$dmg" || die "unsigned app and DMG must have valid strict ad hoc signatures"
  [ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Contents/Info.plist")" = "$version" ] || die "unsigned exported app version differs from $version"
  [ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$app/Contents/Info.plist")" -gt 81 ] || die "unsigned build number must be above 81"
  swiftc -O "$here/ed25519.swift" -o "$work/ed25519" 2>/dev/null
  trusted_key="$(release_public_ed_key)"
  [ "$(/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' "$app/Contents/Info.plist")" = "$trusted_key" ] \
    && release_verify_archive "$zip" "$feed" "$version" "$trusted_key" "$work/ed25519" "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$app/Contents/Info.plist")" \
    || die "archive EdDSA signature does not match AC_PUBLIC_ED_KEY"
  [ -s "$dmg.edSignature" ] && "$work/ed25519" verify "$dmg" "$(cat "$dmg.edSignature")" "$trusted_key" \
    || die "DMG EdDSA signature does not match AC_PUBLIC_ED_KEY"
fi
[ ! -s "$dmg.edSignature" ] || assets+=("$dmg.edSignature")
if ! git -C "$root" ls-remote --exit-code --tags origin "refs/tags/v$version" >/dev/null 2>&1; then
  [ "$dry" = 1 ] && echo "note: v$version isn't on origin yet (git tag v$version && git push origin main v$version)" \
    || die "push the tag first: git tag v$version && git push origin main v$version"
fi
take_lock "$version"
stable_tag="$(gh release view -R "$repo" --json tagName -q .tagName 2>/dev/null || true)"
if [ -z "$stable_tag" ]; then
  [ -z "$(gh release list -R "$repo" --limit 1 --json tagName -q '.[].tagName')" ] \
    || die "couldn't read $repo's latest release"
  [ "$channel" = stable ] \
    || die "$repo has no release yet: the first one is a stable release, since the feed lives on the latest stable release"
  echo "note: $repo has no release yet: $version is the first, and its appcast starts the feed"
  published=""
else
  [[ "$stable_tag" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "the latest release is $stable_tag, not a stable one: the feed lives on the latest stable release"
  published="$(gh release view "$stable_tag" -R "$repo" --json assets -q '.assets[].name')"
fi

if grep -qx appcast.xml <<<"$published"; then
  mkdir -p "$work/live"
  gh release download "$stable_tag" -R "$repo" -p appcast.xml -D "$work/live"
  source="$work/live/appcast.xml"
else
  echo "note: ${stable_tag:-no release} has no appcast.xml yet: $version starts it"
  source=none
fi
merge_dist="$dist"
if [ "$dry" = 1 ]; then
  mkdir -p "$work/dist"
  cp "$dist/appcast.xml" "$work/dist/"
  cp "$dist/appcast.built.xml" "$work/dist/" 2>/dev/null || true
  merge_dist="$work/dist"
fi
RELEASE_DIST="$merge_dist" "$here/appcast-merge.sh" "$version" "$source"
python3 -I - "$merge_dist/appcast.xml" "$version" <<'PY'
import re, sys
path, version = sys.argv[1:]
items = re.findall(r"<item>.*?</item>", open(path).read(), re.S)
def build_of(item):
    found = re.search(r"<sparkle:version>([0-9]+)</sparkle:version>", item)
    return int(found.group(1)) if found else None
mine = [build_of(i) for i in items if f"<sparkle:shortVersionString>{version}<" in i]
others = [build_of(i) for i in items if f"<sparkle:shortVersionString>{version}<" not in i and build_of(i) is not None]
if len(mine) != 1 or mine[0] is None:
    sys.exit(f"error: {path} has {len(mine)} items for {version}, not one")
if others and mine[0] <= max(others):
    sys.exit(f"error: {version} is build {mine[0]}, but the published feed already has build {max(others)}: a stale build would sit below it (and a stable would move latest backward); bump CURRENT_PROJECT_VERSION and rebuild")
print(f"PASS  {version} (build {mine[0]}) is above every other build in {path.rsplit('/', 1)[-1]} ({max(others) if others else 'none'})")
PY
if [ "$channel" = stable ] && [ -n "$stable_tag" ]; then
  latest_version="${stable_tag#v}"
  [ "$version" != "$latest_version" ] && [ "$(printf '%s\n%s\n' "$latest_version" "$version" | sort -V | tail -1)" = "$version" ] \
    || die "$version isn't above the latest stable release ($latest_version): publishing it as latest would move every download and feed backward"
  echo "PASS  $version is above the latest stable release ($latest_version)"
fi

if [ "$channel" = nightly ]; then
  release_flags=(--prerelease --latest=false)
else
  release_flags=(--latest)
fi
run gh release create "v$version" -R "$repo" "${release_flags[@]}" --verify-tag --title "$product $version" \
  --notes-file "$dist/release-notes.md" "${assets[@]}"
if [ "$channel" = nightly ]; then
  nightly_notes="The newest nightly of $product, always as $nightly_dmg ($nightly_url/$nightly_dmg). Now $version: its notes and source are at https://github.com/$repo/releases/tag/v$version. Every nightly's notes: $notes_page"
  if ! gh release view nightly -R "$repo" >/dev/null 2>&1; then
    run gh release create nightly -R "$repo" --prerelease --latest=false --title "$product Nightly" --notes "$nightly_notes"
  fi
  cp -c "$dmg" "$work/$nightly_dmg"
  run gh release upload nightly -R "$repo" --clobber "$work/$nightly_dmg"
  run gh release edit nightly -R "$repo" --notes "$nightly_notes"
  run gh release upload "$stable_tag" -R "$repo" --clobber "$feed"
fi

[ "$dry" = 1 ] && { echo "dry run: nothing published"; exit 0; }
status=0
url="$latest_url/appcast.xml"
for _ in $(seq 1 18); do
  xml="$(curl -fsSL --max-time 20 "$url" 2>/dev/null || true)"
  grep -q "<sparkle:shortVersionString>$version<" <<<"$xml" && break
  sleep 10
done
grep -q "<sparkle:shortVersionString>$version<" <<<"$xml" && echo "PASS  $url lists $version" \
  || { echo "FAIL  $url lists $version"; status=1; }
if [ "$channel" = nightly ]; then
  url="$nightly_url/$nightly_dmg"
  size="$(curl -fsSLI --max-time 30 "$url" | awk 'tolower($1) == "content-length:" { n = $2 } END { print n + 0 }')"
  [ "$size" = "$(stat -f %z "$dmg")" ] && echo "PASS  $url is $version's DMG" \
    || { echo "FAIL  $url is $version's DMG (size $size, expected $(stat -f %z "$dmg"))"; status=1; }
fi
exit $status

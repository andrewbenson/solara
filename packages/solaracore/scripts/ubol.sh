#!/usr/bin/env bash
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
vendor="$(cd "$here/.." && pwd)/vendor"
ubol="$vendor/ubol"
assets="$vendor/ubo/ext/assets/assets.json"
converter="$here/ubol-converter.mjs"
UBOL_VERSION="$(sed -n "s/^export const version = '\(.*\)';$/\1/p" "$converter")"
UBOL_SHA256="$(sed -n "s/^export const archiveSHA256 = '\([0-9a-f]\{64\}\)';$/\1/p" "$converter")"
[ -n "$UBOL_VERSION" ] && [ -n "$UBOL_SHA256" ] || { echo "error: no uBOL pin in $converter" >&2; exit 1; }
[ -f "$assets" ] || { echo "error: uBlock Origin isn't installed ($here/ubo.sh): the WebKit lists take their names from its assets.json" >&2; exit 1; }
stamp="$(cat "$converter" "$here/ubol-cosmetics.mjs" "$here/ubol-verify.mjs" "$here/ubol-pack.mjs" "$assets" | shasum -a 256 | cut -d' ' -f1)"
installed() { [ -f "$ubol/.stamp" ] && [ "$(cat "$ubol/.stamp")" = "$UBOL_VERSION-$stamp" ] && [ -f "$ubol/webkit/manifest.json" ] && [ -f "$ubol/bundle/manifest.json" ]; }
installed && exit 0
mkdir -p "$ubol"
if [ -z "${UBOL_LOCKED:-}" ]; then
  UBOL_LOCKED=1 exec lockf -k -t 600 "$ubol/.lock" "$0" "$@"
fi
work="$(mktemp -d "$ubol/.install.XXXXXXXX")"
cleanup() {
  for name in webkit bundle; do
    if [ ! -d "$ubol/$name" ] && [ -d "$work/previous-$name" ]; then mv "$work/previous-$name" "$ubol/$name"; fi
  done
  rm -rf "$work"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
archive="$ubol/uBOLite_$UBOL_VERSION.chromium.zip"
if [ -f "$archive" ] && ! printf '%s  %s\n' "$UBOL_SHA256" "$archive" | shasum -a 256 -c - > /dev/null 2>&1; then
  echo "warning: $archive fails its SHA-256 check; downloading it again" >&2
  mv "$archive" "$work/stale.zip"
fi
if [ ! -f "$archive" ]; then
  url="https://github.com/uBlockOrigin/uBOL-home/releases/download/$UBOL_VERSION/uBOLite_$UBOL_VERSION.chromium.zip"
  echo "Downloading $url"
  curl -fL --proto '=https' --proto-redir '=https' --connect-timeout 15 --max-time 180 --retry 2 -o "$work/archive.zip" "$url"
  printf '%s  %s\n' "$UBOL_SHA256" "$work/archive.zip" | shasum -a 256 -c -
  mv "$work/archive.zip" "$archive"
fi
printf '%s  %s\n' "$UBOL_SHA256" "$archive" | shasum -a 256 -c -
python3 -I - "$archive" "$work/release" <<'PY'
import pathlib, stat, sys, zipfile
archive, output = sys.argv[1:]
with zipfile.ZipFile(archive) as release:
    entries = release.infolist()
    if sum(entry.file_size for entry in entries) > 512 * 1024 * 1024:
        raise SystemExit("error: release expands beyond limit")
    names = set()
    for entry in entries:
        name = pathlib.PurePosixPath(entry.filename)
        mode = entry.external_attr >> 16
        if name.is_absolute() or any(part in ("..", ".") for part in name.parts) or "\\" in entry.filename or stat.S_ISLNK(mode):
            raise SystemExit("error: unsafe archive path")
        if entry.filename in names:
            raise SystemExit("error: duplicate archive entry")
        names.add(entry.filename)
    release.extractall(output)
PY
node "$converter" "$work/release" "$work/webkit" "$assets" > "$work/coverage-summary.json"
node "$here/ubol-verify.mjs" "$work/webkit"
node "$here/ubol-pack.mjs" "$work/webkit" "$work/bundle"
for name in webkit bundle; do
  if [ -d "$ubol/$name" ]; then mv "$ubol/$name" "$work/previous-$name"; fi
done
mv "$work/webkit" "$ubol/webkit"
mv "$work/bundle" "$ubol/bundle"
echo "$UBOL_VERSION-$stamp" > "$ubol/.stamp"
echo "uBOL $UBOL_VERSION: WebKit lists in $ubol/webkit, compressed for the app in $ubol/bundle (coverage.json records each converted and dropped rule)"

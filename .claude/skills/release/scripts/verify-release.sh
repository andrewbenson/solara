#!/usr/bin/env bash

release_public_ed_key() {
  sed -n 's/^AC_PUBLIC_ED_KEY[[:space:]]*=[[:space:]]*//p' "$root/apps/browser/macos/Identity.xcconfig" | tr -d '\r'
}
release_verify_ad_hoc() {
  local details
  codesign --verify --deep --strict "$1" || return 1
  details="$(codesign -dvv "$1" 2>&1)" || return 1
  grep -qx 'Signature=adhoc' <<<"$details" && ! grep -q '^Authority=' <<<"$details"
}
release_is_unsigned_predecessor() {
  local version
  version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$1/Contents/Info.plist")" || return 1
  [[ "$version" =~ ^0\.0\.[0-9]+(-nightly\.[0-9]+)?$ ]] && release_verify_ad_hoc "$1"
}
release_verify_archive() {
  local archive="$1" feed="$2" version="$3" public_key="$4" verifier="$5" expected_build="${6:-}" metadata signature length
  [ -n "$public_key" ] && [ -s "$archive" ] || return 1
  metadata="$(python3 -I - "$feed" "$version" "$expected_build" <<'PY'
import sys, xml.etree.ElementTree as ET
path, version, expected_build = sys.argv[1:]
ns = {"s": "http://www.andymatuschak.org/xml-namespaces/sparkle"}
items = [i for i in ET.parse(path).getroot().findall("./channel/item") if i.findtext("s:shortVersionString", namespaces=ns) == version]
if len(items) != 1:
    sys.exit("error: appcast must have exactly one matching version")
if expected_build and items[0].findtext("s:version", namespaces=ns) != expected_build:
    sys.exit("error: appcast build differs from the supplied app")
enclosures = items[0].findall("enclosure")
if len(enclosures) != 1:
    sys.exit("error: appcast must have exactly one enclosure")
enclosure = enclosures[0]
signature = enclosure.get("{" + ns["s"] + "}edSignature", "")
length = enclosure.get("length", "")
if not signature or not length.isdigit():
    sys.exit("error: appcast enclosure has no EdDSA signature or length")
print(signature)
print(length)
PY
)" || return 1
  signature="$(sed -n '1p' <<<"$metadata")"
  length="$(sed -n '2p' <<<"$metadata")"
  [ "$length" = "$(stat -f %z "$archive")" ] && "$verifier" verify "$archive" "$signature" "$public_key"
}
release_sign_test_copy() {
  if [ "${SOLARA_RELEASE_UNSIGNED:-0}" = 1 ]; then
    codesign --force --timestamp=none --sign - --preserve-metadata=identifier,entitlements,flags,runtime "$1" \
      && release_verify_ad_hoc "$1"
  else
    codesign --force --deep --timestamp=none --sign "$identity" --preserve-metadata=identifier,entitlements,flags,runtime "$1" \
      && codesign --verify --deep --strict "$1"
  fi
}

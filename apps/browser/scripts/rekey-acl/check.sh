#!/bin/bash
# The Safe Storage item's keychain ACL, on a throwaway keychain, never the login keychain.
#
#   apps/browser/scripts/rekey-acl/check.sh [signing identity]
#
# Builds aclcheck.swift (RekeyLoginKeychain's queries, plus kSecUseKeychain / kSecMatchSearchList for the
# throwaway keychain, and its own service names) twice: signed with the team identity (default: the Debug
# build's) and ad hoc. On a keychain made in a temp dir it checks the item the team binary adds (the D path)
# and items made by `security add-generic-password -T` with and without the partition list (the A path):
# the team binary reads and updates with no prompt; the ad hoc one can't read. Prints what the ad hoc
# binary can do besides. Every call runs under a 20 s timeout with user interaction off. The keychain is
# deleted at the end, and the user's keychain search list is checked unchanged.
set -uo pipefail

identity="${1:-Apple Development: Andrew Benson (4B9377Z9W6)}"
here="$(cd "$(dirname "$0")" && pwd)"
work="$(mktemp -d "${TMPDIR:-/tmp}/rekey-acl-XXXXXX")"
keychain="$work/acl-check.keychain-db"
password="acl-$(uuidgen)"
account="Solara ACL Check"
failed=0
searchList="$(security list-keychains -d user)"
defaultKeychain="$(security default-keychain -d user)"

finish() {
  [ -e "$keychain" ] && security delete-keychain "$keychain"
  if [ "$(security list-keychains -d user)" != "$searchList" ] || [ "$(security default-keychain -d user)" != "$defaultKeychain" ]; then
    echo "FAIL  the user's keychain search list or default keychain changed"
    failed=1
  fi
  rm -rf "$work"
  [ "$failed" = 0 ] && echo "all passed" || echo "failed"
  exit "$failed"
}
trap finish EXIT

expect() {
  local name="$1" want="$2"
  shift 2
  local got
  got="$(timeout 20 "$@" 2>&1)"
  if [[ "$got" == $want ]]; then echo "PASS  $name ($got)"; else echo "FAIL  $name: got '$got', want '$want'"; failed=1; fi
}

timeout 300 swiftc -O "$here/aclcheck.swift" -o "$work/aclcheck-team" 2>/dev/null || { echo "FAIL  swiftc"; failed=1; exit; }
cp "$work/aclcheck-team" "$work/aclcheck-adhoc"
timeout 30 codesign --force -s "$identity" -i network.benson.solara.aclcheck "$work/aclcheck-team" 2>/dev/null || { echo "FAIL  signing with $identity (a prompt or no identity)"; failed=1; exit; }
codesign --force -s - -i network.benson.solara.aclcheck "$work/aclcheck-adhoc" 2>/dev/null
team="$work/aclcheck-team"
adhoc="$work/aclcheck-adhoc"

security create-keychain -p "$password" "$keychain" || { failed=1; exit; }
[ "$(security list-keychains -d user)" = "$searchList" ] || { echo "FAIL  create-keychain changed the search list"; failed=1; exit; }
security set-keychain-settings "$keychain"
security unlock-keychain -p "$password" "$keychain"

d="Solara ACL Check D Safe Storage"
expect "D: the team binary adds the item" "add 0" "$team" add "$keychain" "$d" "$account" first
expect "D: the team binary probes it" "exists 0" "$team" exists "$keychain" "$d" "$account"
expect "D: the team binary reads it, no prompt" "read 0 first" "$team" read "$keychain" "$d" "$account"
expect "D: the team binary updates it, no prompt" "update 0" "$team" update "$keychain" "$d" "$account" second
expect "D: the update reads back" "read 0 second" "$team" read "$keychain" "$d" "$account"
expect "D: the ad hoc binary can't read it" "read -25293 " "$adhoc" read "$keychain" "$d" "$account"

for partition in yes no; do
  a="Solara ACL Check A $partition Safe Storage"
  timeout 20 security add-generic-password -s "$a" -a "$account" -w mock_password -T "$team" "$keychain" || failed=1
  [ "$partition" = yes ] && { timeout 20 security set-generic-password-partition-list -S "apple-tool:,apple:,teamid:555T74U353" -s "$a" -a "$account" -k "$password" "$keychain" >/dev/null || failed=1; }
  expect "A ($partition partition list): the team binary reads it, no prompt" "read 0 mock_password" "$team" read "$keychain" "$a" "$account"
  expect "A ($partition partition list): the team binary updates it, no prompt" "update 0" "$team" update "$keychain" "$a" "$account" new
  expect "A ($partition partition list): the update reads back" "read 0 new" "$team" read "$keychain" "$a" "$account"
  expect "A ($partition partition list): the ad hoc binary can't read it" "read -25293 " "$adhoc" read "$keychain" "$a" "$account"
done

echo "NOTE  the ad hoc binary's probe: $(timeout 20 "$adhoc" exists "$keychain" "$d" "$account"); its update: $(timeout 20 "$adhoc" update "$keychain" "$d" "$account" other), then $(timeout 20 "$team" read "$keychain" "$d" "$account")"

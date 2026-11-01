#!/usr/bin/env bash
set -euo pipefail

usage='usage: self-update-proof.sh prepare <0.0.1 Release app> <0.0.2 Release app> <empty absolute work dir> | sign <feed dir> | run <work dir>'
here="$(cd "$(dirname "$0")" && pwd -P)"
root="$(git -C "$here" rev-parse --show-toplevel)"
mode="${1:?$usage}"
shift
fail() { echo "error: $*" >&2; exit 1; }
info() { /usr/libexec/PlistBuddy -c "Print :$2" "$1/Contents/Info.plist"; }
public_key="$(awk '$1 == "AC_PUBLIC_ED_KEY" && $2 == "=" { print $3 }' "$root/apps/browser/macos/Identity.xcconfig")"
[ -n "$public_key" ] || fail 'AC_PUBLIC_ED_KEY is missing'
case "$mode" in
  prepare)
    [ "$#" = 3 ] || fail "$usage"
    old="$1" new="$2" work="$3"
    case "$work" in /*) ;; *) fail 'work must be an absolute scratch path' ;; esac
    [ ! -e "$work" ] || fail 'work already exists; choose a fresh scratch directory'
    [ "$(info "$old" CFBundleShortVersionString)" = 0.0.1 ] || fail 'old app must be 0.0.1'
    [ "$(info "$new" CFBundleShortVersionString)" = 0.0.2 ] || fail 'new app must be independently built 0.0.2'
    old_build="$(info "$old" CFBundleVersion)" new_build="$(info "$new" CFBundleVersion)"
    [[ "$old_build" =~ ^[0-9]+$ && "$new_build" =~ ^[0-9]+$ ]] || fail 'build numbers must be integers'
    [ "$old_build" -gt 81 ] && [ "$new_build" -gt "$old_build" ] || fail 'require old build >=82 and new build strictly greater'
    for source in "$old" "$new"; do
      [ "$(info "$source" SUPublicEDKey)" = "$public_key" ] || fail 'app does not trust AC_PUBLIC_ED_KEY'
    done
    mkdir -p "$work"
    work="$(cd "$work" && pwd -P)"
    mkdir -p "$work/installed" "$work/candidate" "$work/feed" "$work/home/Library/Preferences" "$work/data"
    : > "$work/data/perf-probe"
    cdp_port="${SELF_UPDATE_CDP_PORT:-8799}"
    [[ "$cdp_port" =~ ^[0-9]+$ ]] && [ "$cdp_port" -gt 1023 ] && [ "$cdp_port" -lt 65536 ] || fail 'SELF_UPDATE_CDP_PORT must be 1024..65535'
    port="${SELF_UPDATE_PORT:-8798}"
    [[ "$port" =~ ^[0-9]+$ ]] && [ "$port" -gt 1023 ] && [ "$port" -lt 65536 ] || fail 'SELF_UPDATE_PORT must be 1024..65535'
    feed="http://127.0.0.1:$port/appcast.xml"
    for pair in old new; do
      if [ "$pair" = old ]; then source="$old"; dest="$work/installed/Solara.app"; else source="$new"; dest="$work/candidate/Solara.app"; fi
      "$root/scripts/lib/export-unsigned.sh" "$source" "$dest" "$root/apps/browser/macos/Solara-macOS/Solara.entitlements"
      python3 - "$dest/Contents/Info.plist" "$work" "$feed" "$pair" "$cdp_port" <<'PY'
import plistlib, sys
path, work, feed, role, cdp_port = sys.argv[1:]
with open(path, 'rb') as f: p = plistlib.load(f)
p['CFBundleIdentifier'] = 'com.hill.solara.selfupdatetest'
p['ACUpdateChannel'] = 'stable'
p['SUFeedURL'] = feed
p['SUEnableAutomaticChecks'] = False
p['SUAutomaticallyUpdate'] = True
p['LSEnvironment'] = {'SOLARA_BACKGROUND': '1', 'SOLARA_DATA_DIR': work + '/data', 'SOLARA_UPDATE_FEED_URL': feed, 'HOME': work + '/home', 'CFFIXED_USER_HOME': work + '/home', 'SOLARA_SWITCHES': 'updatePrewarm=off', 'SOLARA_REMOTE_DEBUGGING_PORT': cdp_port}
if role == 'new': p['CFBundleShortVersionString'] = '0.0.2-test'
with open(path, 'wb') as f: plistlib.dump(p, f)
PY
      codesign --force --timestamp=none --sign - --preserve-metadata=entitlements,flags,runtime "$dest"
      codesign --verify --deep --strict "$dest"
      grep -qx 'Signature=adhoc' <<<"$(codesign -dv "$dest" 2>&1)" || fail 'fixture must be ad hoc signed'
    done
    python3 - "$work" "$port" "$new_build" "$public_key" "$cdp_port" <<'PY'
import datetime, json, plistlib, sys
work, port, build, key, cdp_port = sys.argv[1:]
with open(work + '/home/Library/Preferences/com.hill.solara.selfupdatetest.plist', 'wb') as f:
    plistlib.dump({'SUHasLaunchedBefore': True, 'SULastCheckTime': datetime.datetime(2001,1,1), 'SUEnableAutomaticChecks': False, 'SUAutomaticallyUpdate': True, 'SUSendProfileInfo': False}, f)
with open(work + '/proof.json', 'w') as f:
    json.dump({'work': work, 'port': int(port), 'version': '0.0.2-test', 'build': build, 'publicKey': key, 'cdpPort': int(cdp_port)}, f)
PY
    ditto -c -k --keepParent "$work/candidate/Solara.app" "$work/feed/Solara-0.0.2-test.zip"
    python3 - "$work" "$port" "$new_build" <<'PY'
import os, sys, xml.etree.ElementTree as E
work, port, build = sys.argv[1:]
s = 'http://www.andymatuschak.org/xml-namespaces/sparkle'
E.register_namespace('sparkle', s)
rss = E.Element('rss', version='2.0'); channel = E.SubElement(rss, 'channel'); E.SubElement(channel, 'title').text = 'Solara isolated unsigned self-update proof'
item = E.SubElement(channel, 'item'); E.SubElement(item, 'title').text = '0.0.2-test'
E.SubElement(item, '{'+s+'}version').text = build
E.SubElement(item, '{'+s+'}shortVersionString').text = '0.0.2-test'
E.SubElement(item, '{'+s+'}criticalUpdate')
archive = work + '/feed/Solara-0.0.2-test.zip'
E.SubElement(item, 'enclosure', url='http://127.0.0.1:'+port+'/Solara-0.0.2-test.zip', length=str(os.path.getsize(archive)), type='application/octet-stream', attrib={'{'+s+'}edSignature':'UNSIGNED'})
E.ElementTree(rss).write(work + '/feed/appcast.unsigned.xml', encoding='utf-8', xml_declaration=True)
PY
    swiftc -O "$here/self-update-proof.swift" -o "$work/proof-driver"
    printf '%s\n' "Prepared $work. Copy feed/ to the owner's Mac; sign it separately, then return appcast.xml unchanged."
    ;;
  sign)
    [ "$#" = 1 ] || fail "$usage"
    feed_dir="$(cd "$1" && pwd -P)"
    sign_update="${SPARKLE_BIN:-$root/apps/browser/macos/Pods/Sparkle/bin}/sign_update"
    if [ -n "${SPARKLE_KEY_FILE:-}" ]; then
      [ -s "$SPARKLE_KEY_FILE" ] || fail 'SPARKLE_KEY_FILE is missing or empty'
      key_args=(--ed-key-file "$SPARKLE_KEY_FILE")
    else
      key_args=(--account "${SPARKLE_ACCOUNT:-solara}")
    fi
    signature="$("$sign_update" "${key_args[@]}" "$feed_dir/Solara-0.0.2-test.zip" 2>/dev/null | sed -n 's/.*sparkle:edSignature="\([^"]*\)".*/\1/p')"
    [ -n "$signature" ] || fail 'Sparkle archive signing failed; no key material was logged'
    swift "$here/ed25519.swift" verify "$feed_dir/Solara-0.0.2-test.zip" "$signature" "$public_key" || fail 'EdDSA key mismatches AC_PUBLIC_ED_KEY'
    python3 - "$feed_dir" "$signature" <<'PY'
import sys, xml.etree.ElementTree as E
path, signature = sys.argv[1:]
s = 'http://www.andymatuschak.org/xml-namespaces/sparkle'; E.register_namespace('sparkle', s)
tree = E.parse(path + '/appcast.unsigned.xml'); tree.find('./channel/item/enclosure').set('{'+s+'}edSignature', signature)
tree.write(path + '/appcast.xml', encoding='utf-8', xml_declaration=True)
PY
    echo "Signed and verified $feed_dir/appcast.xml; return it with the exact unchanged ZIP."
    ;;
  run)
    [ "$#" = 1 ] || fail "$usage"
    work="$(cd "$1" && pwd -P)"
    [ "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["work"])' "$work/proof.json")" = "$work" ] || fail 'run on the original Hill scratch path'
    port="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["port"])' "$work/proof.json")"
    build="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["build"])' "$work/proof.json")"
    cdp_port="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["cdpPort"])' "$work/proof.json")"
    installed="$work/installed/Solara.app"
    signature="$(python3 -c 'import sys,xml.etree.ElementTree as E; print(E.parse(sys.argv[1]).find("./channel/item/enclosure").get("{http://www.andymatuschak.org/xml-namespaces/sparkle}edSignature", ""))' "$work/feed/appcast.xml")"
    swift "$here/ed25519.swift" verify "$work/feed/Solara-0.0.2-test.zip" "$signature" "$public_key" || fail 'archive signature is invalid for AC_PUBLIC_ED_KEY'
    [ "$(info "$installed" CFBundleShortVersionString)" = 0.0.1 ] || fail 'prepare a fresh 0.0.1 fixture for each run'
    codesign --verify --deep --strict "$installed"
    "$work/proof-driver" preflight
    if nc -z -G 2 127.0.0.1 "$port" 2>/dev/null; then fail "port $port is occupied; use SELF_UPDATE_PORT during prepare"; fi
    server=''
    cleanup() {
      "$work/proof-driver" quit "$installed" >/dev/null 2>&1 || true
      [ -z "$server" ] || { kill "$server"; wait "$server"; } 2>/dev/null || true
    }
    trap cleanup EXIT
    python3 -u -m http.server "$port" --bind 127.0.0.1 --directory "$work/feed" >"$work/http.log" 2>&1 &
    server=$!
    for _ in $(seq 1 30); do
      kill -0 "$server" 2>/dev/null || fail 'local feed server died'
      nc -z -G 1 127.0.0.1 "$port" 2>/dev/null && break
      sleep 1
    done
    nc -z -G 1 127.0.0.1 "$port" 2>/dev/null || fail 'server was not ready in 30 seconds'
    if nc -z -G 2 127.0.0.1 "$cdp_port" 2>/dev/null; then fail "CDP port $cdp_port is occupied; use SELF_UPDATE_CDP_PORT during prepare"; fi
    "$root/scripts/agent/ac" launch "$installed" --data "$work/data" --js none --port "$cdp_port" --env SOLARA_UPDATE_FEED_URL="http://127.0.0.1:$port/appcast.xml" --env SOLARA_SWITCHES=updatePrewarm=off --env HOME="$work/home" --env CFFIXED_USER_HOME="$work/home"
    "$root/scripts/agent/ac" eval "$work/data" 'return Promise.resolve(ac.shell.setAutomaticUpdateChecks(false)).then(() => ac.shell.checkForUpdates()).then(() => ac.shell.updaterState());' >"$work/trigger.json"
    old_pid="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["pid"])' "$work/data/instance.json")"
    "$work/proof-driver" exercise "$installed" "$old_pid" 0.0.2-test "$build" "$work/data" | tee "$work/proof.log"
    node --input-type=module - "$root" "$work" <<'JS'
import { readFileSync, writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";
const [root, work] = process.argv.slice(2);
const { commandIsBinary, processInfo } = await import(pathToFileURL(root + "/scripts/lib/instance.mjs"));
const state = JSON.parse(readFileSync(work + "/data/instance.json", "utf8"));
const proof = JSON.parse(readFileSync(work + "/data/relaunched.json", "utf8"));
const info = processInfo(proof.pid);
if (proof.binary !== state.binary || !info || !commandIsBinary(info.command, state.binary)) throw new Error("relaunched process path does not match the scratch executable");
state.pid = proof.pid; state.started = info.started;
writeFileSync(work + "/data/instance.json", JSON.stringify(state));
JS
    "$root/scripts/agent/ac" eval "$work/data" 'return ac.shell.systemInfo();' --timeout 60000 >"$work/running.json"
    python3 - "$work/running.json" "$build" <<'PY'
import json, sys
with open(sys.argv[1]) as f: info = json.load(f)
assert info['appVersion'] == '0.0.2-test' and info['appBuild'] == sys.argv[2], info
assert info['configuration'] == 'Release' and info['isolatedInstance'], info
PY
    grep -Eq 'GET /appcast.xml[^ ]* HTTP/[^ ]+" 200' "$work/http.log" || fail 'no successful appcast request recorded'
    grep -Eq 'GET /Solara-0.0.2-test.zip HTTP/[^ ]+" 200' "$work/http.log" || fail 'no successful archive download recorded'
    codesign --verify --deep --strict "$installed"
    grep -qx 'Signature=adhoc' <<<"$(codesign -dv "$installed" 2>&1)" || fail 'installed signature is not ad hoc'
    mtree -c -k type,mode,link,size,sha256digest -p "$work/candidate/Solara.app" >"$work/candidate.mtree"
    mtree -p "$installed" -f "$work/candidate.mtree" >"$work/bundle-differences.log" 2>&1 || fail 'installed bundle differs from the signed archive candidate'
    echo "PASS  found, downloaded, installed and relaunched 0.0.2-test build $build at $installed; evidence: $work"
    ;;
  *) fail "$usage" ;;
esac

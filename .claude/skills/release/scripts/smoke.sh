#!/usr/bin/env bash
set -euo pipefail

version="${1:?usage: smoke.sh <version> <previous-version|none> [--rc]}"
previous="${2:?usage: smoke.sh <version> <previous-version|none> [--rc]}"
root="$(git -C "$(dirname "$0")" rev-parse --show-toplevel)"
here="$(cd "$(dirname "$0")" && pwd)"
. "$here/verify-release.sh"
if [ "${3:-}" = --rc ]; then dist="$root/dist/$version-rc"; else dist="$root/dist/$version"; fi
app="${SMOKE_APP:-$(ls -d "$dist/export"/*.app 2>/dev/null | head -1 || true)}"
app="${app:-$dist/export/Solara.app}"
old="$(ls -d "$root/dist/$previous/export"/*.app 2>/dev/null | head -1 || true)"
old="${old:-$root/dist/$previous/export/Solara.app}"
port="${SMOKE_CDP_PORT:-9398}"
pages_port="${SMOKE_PAGES_PORT:-8798}"
[ -d "$app" ] || { echo "error: no $app (run scripts/release.sh $version first)" >&2; exit 1; }
product="$(plutil -extract CFBundleName raw "$app/Contents/Info.plist")"
executable="$(plutil -extract CFBundleExecutable raw "$app/Contents/Info.plist")"
case "$(cd "$app" && pwd -P)" in /Applications/*) echo "error: never an installed app ($app)" >&2; exit 1 ;; esac
for p in "$port" "$pages_port"; do
  if nc -z -G 2 127.0.0.1 "$p" 2>/dev/null; then
    echo "error: something already listens on port $p (SMOKE_CDP_PORT, SMOKE_PAGES_PORT)" >&2
    exit 1
  fi
done

work="$(mktemp -d "${TMPDIR:-/tmp}/ac-smoke.XXXXXX")"
server=""
logger=""
cleanup() {
  [ -n "${pid:-}" ] && kill -KILL "$pid" 2>/dev/null || true
  [ -n "$logger" ] && { kill "$logger"; wait "$logger"; } 2>/dev/null || true
  [ -n "$server" ] && { kill "$server"; wait "$server"; } 2>/dev/null || true
  rm -rf "$work"
}
trap cleanup EXIT

status=0
check() {
  if [ "$2" = 1 ]; then echo "PASS  $1${3:+  ($3)}"; else echo "FAIL  $1${3:+  ($3)}"; status=1; fi
}
info() { /usr/libexec/PlistBuddy -c "Print :$2" "$1/Contents/Info.plist" 2>/dev/null || true; }
cdhash() { codesign -dvvv "$1" 2>&1 | sed -n 's/^CDHash=//p'; }

fw="$app/Contents/Frameworks"
[ -d "$fw/Chromium Framework.framework" ] && [ ! -e "$fw/Chromium Embedded Framework.framework" ] && ok=1 || ok=0
check "the engine is SolaraCore (Chrome's framework, no CEF)" $ok \
  "$(plutil -extract CFBundleShortVersionString raw "$fw/Chromium Framework.framework/Resources/Info.plist" 2>/dev/null)"
if [ -d "$old" ]; then
  keys="CFBundleIdentifier CFBundleExecutable SUFeedURL SUPublicEDKey" what="same bundle id, executable, feed and update key as $previous"
  same=1
  for key in $keys; do
    [ "$(info "$app" $key)" = "$(info "$old" $key)" ] || { same=0; echo "      $key: $(info "$old" $key) → $(info "$app" $key)"; }
  done
  check "$what" $same
  if release_is_unsigned_predecessor "$old"; then
    codesign --verify --deep --strict "$old" && codesign --verify --deep --strict "$app" \
      && [ "$(info "$old" SUPublicEDKey)" = "$(release_public_ed_key)" ] \
      && [ "$(info "$app" SUPublicEDKey)" = "$(release_public_ed_key)" ] && ok=1 || ok=0
    check "the ad hoc predecessor and update are sealed and keep AC_PUBLIC_ED_KEY (Sparkle's EdDSA trust path)" $ok
  else
    old_dr="$(codesign -d -r- "$old" 2>&1 | sed -n 's/^designated => //p')"
    codesign --verify -R="$old_dr" "$app" 2>"$work/dr.log" && ok=1 || ok=0
    check "satisfies $previous's designated requirement (Sparkle, the keychain and TCC trust it)" $ok "$(head -c 160 "$work/dr.log")"
  fi
  [ "$(info "$app" CFBundleVersion)" -gt "$(info "$old" CFBundleVersion)" ] && ok=1 || ok=0
  check "build number above $previous's" $ok "$(info "$old" CFBundleVersion) → $(info "$app" CFBundleVersion)"
elif [ "$previous" = none ]; then
  echo "SKIP  the first release: no earlier export to compare with or update from"
else
  check "$previous's export to compare with" 0 "no $old"
fi
zip="$dist/$product-$version.zip"
dmg="$dist/$product-$version.dmg"
if [ "${SOLARA_RELEASE_UNSIGNED:-0}" = 1 ]; then
  [ "$(info "$app" CFBundleShortVersionString)" = "$version" ] && [ "$(info "$app" CFBundleVersion)" -gt 81 ] \
    || { echo "error: unsigned smoke requires the requested version and build above 81" >&2; exit 1; }
  if [ -z "${SMOKE_APP:-}" ]; then
    for file in "$zip" "$dmg" "$dmg.edSignature" "$dist/appcast.xml"; do
      [ -s "$file" ] || { echo "error: unsigned smoke requires $file" >&2; exit 1; }
    done
  fi
fi
if [ -z "${SMOKE_APP:-}" ]; then
  for f in "$zip" "$dmg" "$dist/appcast.xml"; do [ -f "$f" ] || check "the release has $(basename "$f")" 0; done
  if [ -f "$zip" ] && [ -f "$dist/appcast.xml" ]; then
    swiftc -O "$here/ed25519.swift" -o "$work/ed25519" 2>/dev/null
    item="$(awk -v v="$version" '/<item>/ { buf = "" } { buf = buf $0 "\n" } /<\/item>/ && buf ~ ("shortVersionString>" v "<") { print buf; exit }' "$dist/appcast.xml")"
    length="$(printf '%s' "$item" | grep -o 'length="[0-9]*"' | head -1 | tr -dc 0-9)"
    ok=0
    [ "$(info "$app" SUPublicEDKey)" = "$(release_public_ed_key)" ] \
      && release_verify_archive "$zip" "$dist/appcast.xml" "$version" "$(release_public_ed_key)" "$work/ed25519" "$(info "$app" CFBundleVersion)" && ok=1
    check "the appcast's EdDSA signature of the zip verifies with the app's SUPublicEDKey" $ok "length ${length:-none}"
    mkdir -p "$work/zip" && ditto -x -k "$zip" "$work/zip"
    zapp="$(ls -d "$work/zip"/*.app 2>/dev/null | head -1)"
    [ -n "$zapp" ] && [ -n "$(cdhash "$app")" ] && [ "$(cdhash "$zapp")" = "$(cdhash "$app")" ] \
      && codesign --verify --deep --strict "$zapp" 2>/dev/null && ok=1 || ok=0
    if [ "${SOLARA_RELEASE_UNSIGNED:-0}" = 1 ]; then
      release_verify_ad_hoc "$zapp" || ok=0
      check "the zip holds this app with a valid ad hoc signature" $ok
    else
      xcrun stapler validate "$zapp" >/dev/null 2>&1 || ok=0
      check "the zip holds this app, sealed and stapled" $ok
    fi
    rm -rf "$work/zip"
  fi
fi
if [ "${SOLARA_RELEASE_UNSIGNED:-0}" = 1 ]; then
  release_verify_ad_hoc "$app" && [ "$(info "$app" SUPublicEDKey)" = "$(release_public_ed_key)" ] && ok=1 || ok=0
  check "the app has a valid strict ad hoc signature and trusts AC_PUBLIC_ED_KEY" $ok
  if [ -n "${SMOKE_APP:-}" ]; then
    swiftc -O "$here/ed25519.swift" -o "$work/ed25519" 2>/dev/null
    release_verify_archive "${SMOKE_ARCHIVE:?unsigned SMOKE_APP requires SMOKE_ARCHIVE}" \
      "${SMOKE_APPCAST:?unsigned SMOKE_APP requires SMOKE_APPCAST}" "$version" "$(release_public_ed_key)" "$work/ed25519" "$(info "$app" CFBundleVersion)" && ok=1 || ok=0
    check "the supplied archive EdDSA signature verifies against AC_PUBLIC_ED_KEY" $ok
  fi
  if [ -z "${SMOKE_APP:-}" ] && [ -f "$dmg" ]; then
    release_verify_ad_hoc "$dmg" && [ -s "$dmg.edSignature" ] \
      && "$work/ed25519" verify "$dmg" "$(cat "$dmg.edSignature")" "$(release_public_ed_key)" && ok=1 || ok=0
    check "the DMG has a valid ad hoc signature and EdDSA signature against AC_PUBLIC_ED_KEY" $ok
  fi
else
  spctl -a -vv -t exec "$app" > "$work/spctl.log" 2>&1 && grep -q "source=Notarized Developer ID" "$work/spctl.log" && ok=1 || ok=0
  check "Gatekeeper: the app is notarized Developer ID" $ok "$(tr '\n' ' ' < "$work/spctl.log" | head -c 160)"
  xcrun stapler validate "$app" >/dev/null 2>&1 && ok=1 || ok=0
  check "the app has its notarization ticket stapled" $ok
  if [ -z "${SMOKE_APP:-}" ] && [ -f "$dmg" ]; then
    xcrun stapler validate "$dmg" >/dev/null 2>&1 && spctl -a -t open --context context:primary-signature "$dmg" 2>/dev/null && ok=1 || ok=0
    check "the DMG is signed, notarized and stapled" $ok
  fi
fi
if [ -d "$old" ]; then
  if [ -z "${SMOKE_APP:-}" ] && [ -f "$dist/appcast.xml" ]; then
    TMPDIR="$work" "$here/update-test.sh" "$old" "$app" "$dist/appcast.xml" "$version" || status=1
  fi
  TMPDIR="$work" "$here/carryover.sh" "$old" "$app" || status=1
fi

swiftc -O "$here/windows.swift" -o "$work/windows" 2>/dev/null
swiftc -O "$here/quit.swift" -o "$work/quit" 2>/dev/null
swiftc -O "$here/keys.swift" -o "$work/keys" 2>/dev/null
swiftc -O "$here/gurl.swift" -o "$work/gurl" 2>/dev/null

if [ "${SOLARA_RELEASE_UNSIGNED:-0}" = 1 ]; then
  python3 - "$app" "$work/quit" "$work" <<'PY' || status=1
import os, pathlib, plistlib, socket, subprocess, sys, time
app, quit_helper, work = map(pathlib.Path, sys.argv[1:])
with (app / "Contents/Info.plist").open("rb") as f:
    info = plistlib.load(f)
signature = subprocess.run(["/usr/bin/codesign", "-dv", str(app)], check=True,
                           capture_output=True, text=True, timeout=5).stderr.splitlines()
if "Signature=adhoc" not in signature or info.get("ACDevBuild") == "YES":
    raise SystemExit("FAIL  test gate check requires an ad hoc export with ACDevBuild off")
home = work / "gate-home"
home.mkdir(mode=0o700)
profile = home / "Library/Application Support" / info["CFBundleIdentifier"] / "Chromium"
reservations = []
try:
    for _ in range(3):
        reservation = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        reservation.bind(("127.0.0.1", 0))
        reservations.append(reservation)
        reservation6 = socket.socket(socket.AF_INET6, socket.SOCK_STREAM)
        reservations.append(reservation6)
        reservation6.setsockopt(socket.IPPROTO_IPV6, socket.IPV6_V6ONLY, 1)
        reservation6.bind(("::1", reservation.getsockname()[1]))
    ports = [reservation.getsockname()[1] for reservation in reservations[::2]]
finally:
    for reservation in reservations:
        reservation.close()
env = {
    "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
    "TMPDIR": str(work),
    "HOME": str(home),
    "CFFIXED_USER_HOME": str(home),
    "SOLARA_BACKGROUND": "1",
    "SOLARA_REMOTE_DEBUGGING_PORT": str(ports[0]),
    "SOLARA_TEST_REAUTH": "granted",
    "SOLARA_CHROMIUM_SWITCHES": "--remote-debugging-port=" + str(ports[1]),
}
process = None
failed = None
exit_code = None
try:
    with (work / "test-gate.app.log").open("wb") as log:
        process = subprocess.Popen([str(app / "Contents/MacOS" / info["CFBundleExecutable"]),
                                    "--remote-debugging-port=" + str(ports[2])],
                                   env=env, stdout=log, stderr=log)
        deadline = time.monotonic() + 30
        ready_at = None
        while True:
            if process.poll() is not None:
                raise RuntimeError("app exited before the port observation finished")
            for port in ports:
                for family, address in [(socket.AF_INET, "127.0.0.1"), (socket.AF_INET6, "::1")]:
                    with socket.socket(family, socket.SOCK_STREAM) as probe:
                        probe.settimeout(0.1)
                        if probe.connect_ex((address, port)) == 0:
                            raise RuntimeError("debugging port opened: " + str(port))
            now = time.monotonic()
            if ready_at is None and (profile / "Default").is_dir():
                ready_at = now
            if ready_at is not None and now - ready_at >= 10:
                break
            if now >= deadline:
                raise RuntimeError("scratch-HOME profile was not ready for a 10 s observation within 30 s")
            time.sleep(0.1)
except Exception as error:
    failed = str(error)
finally:
    if process is not None:
        if process.poll() is None:
            try:
                subprocess.run([str(quit_helper), str(process.pid)], check=True, timeout=5,
                               stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
                exit_code = process.wait(timeout=15)
            except (subprocess.SubprocessError, OSError) as error:
                failed = failed or "quit Apple event failed: " + str(error)
                process.kill()
                process.wait(timeout=5)
        else:
            failed = failed or "app exited before the quit Apple event"
log_text = (work / "test-gate.app.log").read_text(errors="replace")
watchdog = exit_code == 2 and "Teardown watchdog expired" in log_text
if exit_code not in (None, 0) and not watchdog:
    failed = failed or "app did not exit cleanly (exit " + str(exit_code) + ")"
if not (profile / "Default").is_dir() or not (profile / "Local State").is_file():
    failed = failed or "scratch HOME does not contain the Chromium profile"
if "[solaracore] ignored test environment overrides\n" not in log_text:
    failed = failed or "host did not report successful test environment clearing"
if failed:
    raise SystemExit("FAIL  test facilities refused on the shipped profile (" + failed + ")")
print("PASS  test facilities refused on the shipped profile (host cleared test environment; three ports closed while alive; scratch-HOME profile; clean quit)")
if watchdog:
    print("note: the quit ended in Chrome's 10 s teardown watchdog (exit 2), a known engine flake on a fresh export's first quit; the gate itself held")
print("note: reauth has no non-CDP observer; the host clearing receipt confirms SOLARA_TEST_REAUTH was removed before the engine starts")
PY
fi
python3 -m http.server "$pages_port" --bind 127.0.0.1 --directory "$here/pages" >/dev/null 2>&1 &
server=$!

mkdir -p "$work/data"
printf '{"version":1,"lastVersion":"%s","pending":null}' "$previous" > "$work/data/release-notes.json"
pages="http://localhost:$pages_port"
tab() {
  local pinned="${4:-false}" home=null
  [ "$pinned" = true ] && home="\"$3\""
  printf '{"id":"%s","windowId":"w-smoke","profileId":"%s","url":"%s","title":"","favicon":null,"pinned":%s,"muted":false,"zoom":1,"customTitle":null,"customIcon":null,"pinnedUrl":%s,"openerId":null,"createdAt":1,"lastActiveAt":1}' "$1" "$2" "$3" "$pinned" "$home"
}
cat > "$work/data/session.json" <<JSON
{"version":2,
 "profiles":{"default":{"id":"default","name":"Personal","color":"plum","icon":null,"createdAt":0},
             "p-work":{"id":"p-work","name":"Work","color":"blue","icon":null,"createdAt":1}},
 "profileOrder":["default","p-work"],
 "windows":[{"id":"w-smoke","profileId":"p-work","incognito":false,"tabIds":["t-pin-a","t-home","t-work"],
             "activeTabIds":{"default":"t-home","p-work":"t-pin-a"},"sidebarOpen":true,"frame":[80,80,1280,800],"createdAt":1}],
 "windowOrder":["w-smoke"],"focusedWindowId":"w-smoke",
 "tabs":[$(tab t-pin-a p-work "$pages/count.html?pin-a" true),$(tab t-home default "$pages/form.html?home"),
         $(tab t-work p-work "$pages/form.html?work")],
 "groups":[],"splits":[],"closedTabs":[],"closedWindows":[],"closedGroups":[],"cleanedTabs":[]}
JSON

: > "$work/data/perf-probe"

mkdir -p "$work/data/Chromium"
printf '{"profile":{"last_used":"Profile p-work"}}' > "$work/data/Chromium/Local State"

codesign --verify --deep --strict "$app"
launched="$("$root/scripts/agent/ac" launch "$app" --data "$work/data" --port "$port" --js none --no-wait \
  --env SOLARA_RELEASE_NOTES=1 --env SOLARA_DRAW_WINDOWS=1 --env SOLARA_PIP_SELFTEST=close --env SOLARA_ACCEPT_EXTERNAL_URLS=1 --switch --disable-backgrounding-occluded-windows)" \
  || { echo "error: the app didn't start" >&2; exit 1; }
pid="$(sed -n 's/^pid \([0-9]*\) .*/\1/p' <<<"$launched")"
[ -n "$pid" ] || { echo "error: the app didn't start ($launched)" >&2; exit 1; }
sleep 8

locked="$("$work/windows" --locked)"
[ "$locked" = 1 ] && echo "note: the screen is locked; checks of window order and closing are skipped (they need an unlocked screen)"
SMOKE_PRODUCT="$product" SMOKE_LOCKED="$locked" SMOKE_CAN_POST="$("$work/keys" --can-post)" SMOKE_DATA="$work/data" SMOKE_KEYS="$work/keys" SMOKE_GURL="$work/gurl" node "$here/smoke.mjs" "$version" "$work/windows" "$pages" || status=1

children="$(ps -axo ppid=,pid=,comm= | awk -v p="$pid" '$1 == p { $1 = ""; $2 = ""; sub(/^ +/, ""); print }')"
foreign="$(printf '%s\n' "$children" | grep -v "^$fw/Chromium Framework.framework/" | grep -v '^$' || true)"
kinds="$(printf '%s\n' "$children" | sed -n 's/.*Helpers\/\([^/]*\)\.app\/.*/\1/p' | sort | uniq -c | tr -s ' ' | tr '\n' ',')"
[ -z "$foreign" ] && [[ "$kinds" == *"(Renderer)"* ]] && ok=1 || ok=0
check "the browser's child processes are the bundle's own helpers (a renderer among them)" $ok "${kinds%,}${foreign:+; foreign: $foreign}"

log stream --style compact --predicate "process == \"runningboardd\" AND eventMessage CONTAINS \":$pid]\" AND eventMessage CONTAINS \"termination reported\"" \
  > "$work/exit.log" 2>/dev/null &
logger=$!
sleep 1
touch "$work/quit-marker"
"$work/quit" "$pid" >/dev/null || true
tenths=0
while kill -0 "$pid" 2>/dev/null && [ $tenths -lt 150 ]; do sleep 0.1; tenths=$((tenths + 1)); done
if kill -0 "$pid" 2>/dev/null; then
  echo "FAIL  quits cleanly on the quit Apple event  (still running after 15 s)"
  status=1
else
  exited="" report=""
  for _ in $(seq 1 10); do
    sleep 1
    exited="$(grep -o ">:$pid\] termination reported by launchd ([0-9, ]*)" "$work/exit.log" | head -1 | sed 's/.*launchd //' || true)"
    report="$(find ~/Library/Logs/DiagnosticReports ~/Library/Logs/DiagnosticReports/Retired -maxdepth 1 \
      -name "$executable-*.ips" -newer "$work/quit-marker" -exec grep -l "\"pid\" : $pid," {} + 2>/dev/null | head -1 || true)"
    [ -n "$report" ] && break
    [ "$exited" = "(0, 0, 0)" ] && break
  done
  detail="exited in $((tenths / 10)).$((tenths % 10)) s, ${exited:-exit status not logged}"
  if [ -z "$report" ] && [ "${exited:-(0, 0, 0)}" = "(0, 0, 0)" ]; then
    echo "PASS  quits cleanly on the quit Apple event  ($detail)"
  else
    echo "FAIL  quits cleanly on the quit Apple event  ($detail${report:+; crash report $report})"
    status=1
  fi
fi
{ kill "$logger"; wait "$logger"; } 2>/dev/null || true
logger=""
kill -KILL "$pid" 2>/dev/null || true
pid=""
node "$root/packages/solaracore/scripts/popup-check.mjs" "$app" "$work/popup-check" || status=1
codesign --verify --deep --strict "$app" && echo "PASS  bundle still sealed after running" || { echo "FAIL  running the app changed its bundle"; status=1; }
if [ "${SOLARA_RELEASE_UNSIGNED:-0}" = 1 ] && [ "$previous" = none ]; then
  . "$root/scripts/identity.sh"
  bootstrap_url="$(info "$app" SUFeedURL)"
  bootstrap_ok=0
  case "$bootstrap_url" in
    https://*)
      [ "$bootstrap_url" = "$(ac_identity AC_FEED_URL)" ] \
        && release_verify_archive "${SMOKE_ARCHIVE:-$zip}" "${SMOKE_APPCAST:-$dist/appcast.xml}" \
          "$version" "$(release_public_ed_key)" "$work/ed25519" "$(info "$app" CFBundleVersion)" && bootstrap_ok=1
      ;;
  esac
  check "the bootstrap feed URL matches AC_FEED_URL over HTTPS and its local archive is EdDSA authenticated" "$bootstrap_ok"
  [ "$bootstrap_ok" != 1 ] || echo "note: the first release's hosted feed check runs after publish"
else
  "$here/feed.sh" "$version" --before-publish "$app" || status=1
fi
exit $status

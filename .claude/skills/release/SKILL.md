---
name: release
description: Cut and ship a Solara release end to end, stable or nightly — write the Dia-style release notes from git log, bump the version, build/sign/package with scripts/release.sh, smoke-test the build in a hidden instance, publish the GitHub release (a prerelease for a nightly) + Sparkle appcast. Use this whenever the user asks to ship, release, cut/push a new version, a nightly or an update, publish a build, "ship it as a nightly", "get this to me", bump the version, or write release notes for Solara — even if they only say "ship it", "nightly" or "new release" after a batch of fixes.
---

# Releasing Solara

A release is: notes → version bump → `scripts/release.sh` → smoke test → GitHub release.
Users get it through Sparkle (Solara › Check for Updates…), and the first launch of the new version
opens the identity's `AC_NOTES_URL`: for Solara that's the GitHub releases page of `andrewbenson/solara`, so the
release's notes must be on its GitHub release.

Solara releases from this Mac: `scripts/release.sh`, then `publish.sh`, to `andrewbenson/solara` (the
`AC_RELEASE_REPO` in `apps/browser/macos/Identity.xcconfig`). It has no site, no Homebrew tap and no telemetry.

Versions start at **0.0.1**, then add **0.0.1** each owner-only release. All 0.0.x releases are unsigned
(ad hoc code signing, no Developer ID/notarization). **0.1.0 is the first Developer ID signed and notarized release**.
Build numbers continue above 81: 0.0.1 is **82 or higher**, each later build strictly higher, never reset. Historical
0.1.x and 0.2.x regressions named below are from the earlier app, not Solara releases.

## Cutting an unsigned 0.0.x

Export `SOLARA_RELEASE_UNSIGNED=1` before the whole workflow (including smoke/update/channel tests and publish).
`release.sh --unsigned` affects only release.sh. Bump both project configurations to the intended 0.0.x and a build
above 81 and every published build, write notes, commit, then follow the stable steps below. The script rejects a
stable unsigned version outside 0.0.x and any signed 0.0.x. Keep the existing bundle id and `AC_PUBLIC_ED_KEY`.

```bash
export SOLARA_RELEASE_UNSIGNED=1
APPCAST_BASE=none scripts/release.sh 0.0.1
.claude/skills/release/scripts/smoke.sh 0.0.1 none
.claude/skills/release/scripts/publish.sh 0.0.1 --dry-run
```

Only the first release uses `APPCAST_BASE=none`; later builds read the published feed and smoke against the previous
export. Unsigned mode checks ad hoc signatures, deep strict validity and EdDSA archive signatures in place of Apple
identity, Gatekeeper and stapler checks. It still signs the update ZIP with the real Sparkle key and verifies against
`AC_PUBLIC_ED_KEY`; a missing or different key fails. Use `SPARKLE_KEY_FILE` only on the signing Mac and never log it.
`docs/releasing.md` has the split Hill Studio build / owner's Mac light sign / Hill Studio self-update proof. Run that
proof before shipping 0.0.1; the existing external-host update test does not prove a running app's relaunch. Owner-only
is an audience rule; GitHub public releases do not restrict downloads. For 0.1.0, unset `SOLARA_RELEASE_UNSIGNED`,
configure Developer ID + notarization, retain the bundle id and EdDSA key, and repeat the transition proof.

There are two channels (`docs/releasing.md` › Channels):

- **Nightly** (`0.1.3-nightly.1`): fast iteration, one fix at a time. Only the focused checks for what changed run;
  no perf ratchet, no perf gate. It's a GitHub prerelease, so `releases/latest` keeps pointing at stable.
- **Stable** (`0.1.2`): everything below, about 1.5 h with the smoke test, the update test, the ratchet and the
  perf gate. Its perf is compared with the previous **stable** release, never a nightly.

When the owner asks for a nightly, or a fix is ready and nobody said stable, run the nightly loop.

## The nightly loop

For each fix:

1. **Reproduce** it in a hidden instance (or the test that shows it) before touching code.
2. **Fix** it; commit straight to `main` (only your hunks).
3. **Verify** the fix the same way you reproduced it, once before and once after.
4. **Run the adjacent tests**: the checks for what changed (its acceptance checks, `packages/core` tests, the shortcut
   test, a smoke.mjs check), not the full suite.
5. **Build and release it as a nightly**:
   ```bash
   prev="$(git describe --tags --abbrev=0 --match 'v*' 2>/dev/null)"                          # the previous release, either channel
   stable="$(git describe --tags --abbrev=0 --match 'v*' --exclude '*-nightly*' 2>/dev/null)"  # the previous stable
   ```
   - Version: `<next stable>-nightly.<n>`, where the next stable is `$stable` with the patch bumped and `<n>` counts up
     from 1 since `$stable` (`git tag -l "v<next stable>-nightly.*"`). The build number goes up by one, as always.
     With no stable yet (`$stable` empty), there's no nightly: cut the first release, unsigned 0.0.1 (step 0).
   - Notes: `docs/release-notes/<version>.md` with `channel: nightly` in the frontmatter, the headline and one to three
     bullets (`docs/release-notes/README.md` › Nightlies). Source: `git log $prev..HEAD -- apps/browser packages engine`.
   - Bump and build: step 3 below, with `scripts/release.sh <version> --channel nightly`.
   - Smoke test: `.claude/skills/release/scripts/smoke.sh <version> ${prev#v}`. Its update test runs the nightly's own
     appcast item twice: a copy of the previous build on Stable must not be offered it, one on Nightly must install it.
     All of it must pass, as for stable.
   - Publish: `git tag v<version> && git push origin main v<version>`, then
     `.claude/skills/release/scripts/publish.sh <version>` (a prerelease with the DMG, zip, appcast and CLI tarball; the
     merged feed onto the latest stable release; `<Product>-Nightly.dmg` (`Solara-Nightly.dmg`) on the `nightly` release; it checks them;
     every release asset is named for the identity's product). With a new engine, commit `prebuilt-engine.tsv`'s
     line as in step 5.
   - Report in two lines: the version, the fix, the smoke result.

Batch nightlies when fixes land close together; never hold a fix back for a stable. A stable release's notes cover
everything since the previous stable, nightlies included.

`docs/releasing.md` is the reference for the machinery (keys, notarization, what release.sh checks);
`docs/release-notes/README.md` is the notes style guide. Read the style guide before writing notes.

## Ground rules (why they exist)

- **Never touch the Chromium build cache.** release.sh only reads the engine framework from
  `~/chromium-build/chromium_git/chromium/src/out/Release_GN_arm64` (and refuses one older than the tree's SolaraCore
  sources: rebuilding it is an incremental `chrome_framework` build under the chromium lock). Never delete or clean
  `~/chromium-build/chromium_git/chromium/src/out`, run `gclient sync` or `gn clean`: a full Chromium
  rebuild costs ~5 hours and the user has been emphatic about it.
- **Never launch or touch `/Applications/Solara.app`** (`Netnyahoo.app` until the owner updates past the rename), nor
  an installed `/Applications/Solara.app` — the user is using them. Test only the exported
  build in `dist/`, only hidden (`SOLARA_BACKGROUND=1`, throwaway `SOLARA_DATA_DIR`), never with
  plain `open`. The smoke script does this for you.
- **Build from a clean tree.** release.sh archives the working tree, so another agent's half-finished
  edit would ship. Check `git status` first (below).
- **Commits** go to `main`.

## 0. The first release

With no `v*` tag (`git describe --tags --match 'v*'` finds nothing), the release is Solara's first: stable unsigned 0.0.1
(set `MARKETING_VERSION=0.0.1` and `CURRENT_PROJECT_VERSION` to at least 82 in both configurations). Follow the steps below with these differences
(`docs/releasing.md` › The first release):

- Notes: from every commit since the code Solara began from, `git log --no-merges --format='%h %s%n%b' main --not c508a9f33566
  -- apps/browser packages engine` (c508a9f33566 is the last commit Solara took from the code it began from), written for people meeting Solara for the first time.
- Build: `SOLARA_RELEASE_UNSIGNED=1 APPCAST_BASE=none scripts/release.sh 0.0.1` (there's no published feed to build on).
- Smoke test: `SOLARA_RELEASE_UNSIGNED=1 .claude/skills/release/scripts/smoke.sh 0.0.1 none` (no earlier export: the update, carryover and same-identity checks are skipped).
- Perf: run the ratchet as usual. There's no previous stable to gate against, so run native-bench and js-bench on
  0.0.1 alone and record them in `docs/perf/0.0.1-baseline.md`; keep `dist/0.0.1/export` as the next stable's control.
- Publish: `publish.sh` sees no release in the repo and publishes 0.0.1's appcast as the feed. First run the real self-update proof in `docs/releasing.md`.

## 1. Check the tree

```bash
git status --short
git log --oneline v<previous>..HEAD
```

Anything modified or untracked under `apps/browser`, `packages/`, `engine/` or `scripts/dmg` that isn't committed
would end up in the build (release.sh refuses to run with it). If it belongs to a running agent, wait for it or ask; don't commit
someone else's work in progress. Untracked files under `output/` don't affect the app.

For a stable release `<previous>` is the last stable tag (`git describe --tags --abbrev=0 --match 'v*' --exclude
'*-nightly*'`); nightlies in between don't count, for the notes range, the smoke test or the perf gate. The next version
bumps the patch (0.1.5 → 0.1.6) unless the user says otherwise. With no stable tag yet, it's the first release (step 0).

## 2. Write the notes

First update `docs/roadmap.md`: mark this version's landed items shipped, move anything unfinished to the next version
or back to `docs/backlog.md`, and check that the notes and the roadmap agree.


Create `docs/release-notes/<version>.md` following `docs/release-notes/README.md`: frontmatter `date`
(today, `YYYY-MM-DD`) and `headline` (30–60 chars, one sentence, the only witty line: the most noticeable
change said dry and calm, true, no pun and no politics, with an open-country touch only where it fits, per
the README's Voice section), then `## New` / `## Faster` (the
perf-gate table, step 4c) / `## Fixed` / `## Smaller` bullets written from the user's side.

Source material: `git log --format='%h %s%n%b' v<previous>..HEAD -- apps/browser packages`. The commit
bodies already describe the user-visible symptom; translate them, don't paste them. Leave out docs
and version bumps that changed nothing visible. Each bold lead says what the user can do or what stopped being
broken; no file names, flags or commit hashes. Items that came from an outside contributor's PR, or a
commit co-authored by one, end with `Thanks, [@handle](<PR url>).` (README step 5); check
`git log --format='%h %an %(trailers:key=Co-authored-by)' v<previous>..HEAD` and the merged PRs
(`gh pr list --state merged --search "merged:>=<previous release date>"`) so nobody is missed.

The notes are read on the GitHub release (the after-update tab opens `AC_NOTES_URL`, the releases page), so check
the release body there once it's published.

## 3. Bump and build

First bring the content blocker up to date. uBlock Origin is bundled as a component extension, which
never updates itself, so its code is only as fresh as the last release that moved the pin (its filter lists
update themselves from the network, as uBO's do everywhere):

```bash
scripts/update-ubo.sh     # "uBO <x> is the latest release", or "uBO <old> -> <new> (sha256 …)"
git add packages/solaracore/scripts/ubo.sh && git commit -m "Content blocker: uBlock Origin <new>"   # only if it moved
```

It checks the zip against GitHub's SHA-256 digest and the manifest's version, rewrites the pin in
`packages/solaracore/scripts/ubo.sh` and installs it into `packages/solaracore/vendor/ubo`. Verify after release.sh
that the export carries it: `python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["version"])'
dist/<version>/export/Solara.app/Contents/Resources/Extensions/ublock/manifest.json` prints the
pinned `UBO_VERSION` followed by ubo.sh's patch level as a fourth part (`1.75.0.8`: uBO refreshes its cached
scriptlets when that version changes, so our patches reach existing profiles), and the smoke test's "uBlock blocks an ad script" check passes. An error means
the release is odd (no digest, a version mismatch): keep the old pin and say so in the report.

```bash
sed -i '' 's/MARKETING_VERSION = <previous>;/MARKETING_VERSION = <version>;/; s/CURRENT_PROJECT_VERSION = <n>;/CURRENT_PROJECT_VERSION = <n+1>;/' \
  apps/browser/macos/Solara.xcodeproj/project.pbxproj
git add docs/release-notes/<version>.md apps/browser/macos/Solara.xcodeproj/project.pbxproj
git commit -m "Release <version>"
scripts/release.sh <version>     # ~15–25 min with notarization; run it in the background and wait
```

For a nightly, set `MARKETING_VERSION` to `<version>` (`0.1.1-nightly.1`) the same way, commit as "Nightly <version>",
and run `scripts/release.sh <version> --channel nightly`.

`CURRENT_PROJECT_VERSION` is the build number Sparkle compares — it must go up every release, nightlies included
(release.sh refuses one that isn't above every build in the published feed; read the current value with `grep CURRENT_PROJECT_VERSION …project.pbxproj | sort -u`). release.sh refuses to run
if `MARKETING_VERSION` doesn't match, the notes file is missing, the tree has uncommitted app or engine
changes, or the engine framework is stale (`docs/releasing.md` lists what it checks). It notarizes the app and the DMG with the
`solara` notarytool profile (an App Store Connect API key in the login keychain, set up 2026-09-26) and
ends with "Notarized and stapled." If it says "NOT notarized.", the profile is gone or invalid
(`xcrun notarytool history --keychain-profile solara` shows why): stop and tell the user rather than
shipping an unnotarized build. Never store or re-create the credential yourself; that's the user's step.
Notarization adds a few minutes per submission.

## 4. Smoke test the build

```bash
.claude/skills/release/scripts/smoke.sh <version> <previous>     # --rc for dist/<version>-rc
```

First it checks the update from `<previous>` (its export in `dist/<previous>/export`):

- the engine is SolaraCore (Chrome's framework, no CEF);
- the identity Sparkle, the keychain and TCC compare: same bundle id, executable, feed and EdDSA key, the build
  satisfies `<previous>`'s designated requirement for signed predecessors; an ad hoc 0.0.x predecessor instead
  requires valid seals and EdDSA key continuity. The build number is higher;
- the appcast's EdDSA signature of the zip verifies with the app's key, and the zip holds this very app, sealed and
  stapled in signed mode; Gatekeeper accepts signed app/DMG as notarized. Unsigned mode checks ad hoc signatures
  and strict seals instead, plus the DMG EdDSA sidecar;
- `update-test.sh`: `<previous>`'s own Sparkle updates a scratch copy of it to this build, through a local feed made of
  the appcast's item (test bundle id and key; no relaunch, no UI);
- `carryover.sh`: `<previous>`'s data, made where an installed copy keeps it (two profiles: tabs, cookies including
  session ones, localStorage, passwords, bookmarks, history, an address, a site permission, zoom, an extension),
  opens in this build started without `SOLARA_DATA_DIR` (test copies in a fake home; never the real data).

Then it launches `dist/<version>/export/Solara.app` hidden with a data dir that says `<previous>` ran last,
and a session whose window was left on its second profile, and checks, over CDP and the window list:

- the engine and chrome://version are the Chromium version `engine/patches/build/env.sh` names, and the after-update release-notes tab opened exactly once;
- the browser's child processes are the bundle's own helpers (Chrome's process checks pass under Developer ID);
- pages load, uBlock blocks an ad script, H.264/AAC/WebGL2;
- no hidden full-size Chrome window (since 0.2.0 the app window is Chrome's own; before, a hidden "ghost"
  sat behind it), and the window restores as the Work profile's Chrome window, alone on screen, its pages
  in the Work context;
- a passkey dialog comes in front, directly over the visible window it belongs to, and closes when the
  page navigates (Solara's 0.1.2–0.1.4 regressions);
- the autofill dropdown accepts a suggestion (Solara 0.1.3), the offline page is Where's the raccoon?, chrome://version;
- right-click shows the native context menu (Solara 0.1.5);
- with Chrome's last-used profile left at Work (as quitting with Work's window in front does), Personal's pages
  still run in Personal's profile (0.2.19 and earlier ran them in Work's);
- a page that stops responding is reported (Chrome's hang monitor reaches the app; 0.2.20 attached a DevTools client to
  every tab it showed, and Chrome ignores hangs while one is attached);
- quitting the way ⌘Q and Sparkle's update do (the quit Apple event, sent to this instance's pid only) exits
  within 15 s with status 0 and no crash report (0.2.6 and 0.2.7 crashed on every quit, so every update
  ended in "<product> quit unexpectedly");
- the bundle's signature is still valid after running (Solara 0.1.0 wrote into its own bundle);
- the feed in the build's Info.plist (`SUFeedURL`: GitHub's `releases/latest/download/appcast.xml`) answers with an
  appcast (`.claude/skills/release/scripts/feed.sh --before-publish`).

smoke.sh launches with `SOLARA_DRAW_WINDOWS=1`: these checks read the window server's own alpha and stacking, so its windows are
drawn (and show wherever the desktop is uncovered) rather than kept at alpha 0 like other hidden instances.

Everything must pass before publishing. One known exception: the two passkey window-order checks read
CGWindowList, which isn't reliable while the Mac's screen is locked (window animations freeze). smoke.sh
detects the lock (`CGSSessionScreenIsLocked`) and prints them as SKIP; publish when the release doesn't
touch window ordering, and say so in the report. Before 0.2.0 the builds had three such checks (the
ghost's order), so a pre-0.2.0 export isn't a control for these. The window-list checks also fail, with an empty or
shrunken list, when the user switches Spaces or opens Mission Control during the run (the hidden instance's
windows leave the on-screen list): run it again. A failure is either a real regression (fix it, commit, rebuild —
don't publish) or the check itself going stale after an intended change (fix the check in
`.claude/skills/release/scripts/smoke.mjs`, and say so). When a release fixes a new class of bug that can be observed over CDP or
the window list, add a check for it to `smoke.mjs` so the next release guards it.

### 4b. Perf ratchet (stable only)

Check the candidate's counts against the ceilings before publishing (about two minutes, no perflab lock needed: they
are counts, not timings):

```bash
node apps/browser/scripts/perf/ratchet.mjs run --own --app dist/<version>-rc/export/Solara.app   # dist/<version>/export without an rc
```

`--own` runs the app's own `main.jsbundle`, so it checks what ships. It must print `ratchet: ok`. It runs the launch,
idle, command bar, tab switch, navigate, scroll and hover scenarios in a hidden instance, and a count over its ceiling
gets one more run (a stray window event isn't a regression; a count over in both is). A failure is a real regression
(find the commit that added the commit, render, store update or timer, and fix it) or an intended increase: raise that
one ceiling by hand in `apps/browser/scripts/perf/ratchet.json` and say why in the commit and the release report. When
the release made counts go down, run `ratchet.mjs lower <the run's report>` (`$TMPDIR/ac-ratchet/ratchet.json`), commit
the lowered ceilings, and say which counts dropped. The wall-clock gate is a separate step: `docs/perf/README.md`.

### 4c. Perf gate: the RC against the previous stable release (stable only)

Every stable release is timed against the previous stable one before it publishes (never against a nightly: the
control is `dist/<previous stable>/export/Solara.app`), and ships only when every row is the same or
better (`docs/perf/README.md` › Gating a release: native-bench with `--control dist/<previous>/export/Solara.app`,
interleaved, launch x6+ and session x2, then js-bench alternating the two apps). It runs alone on a quiet Mac, holding
the perflab lock, after the smoke test and the ratchet. Call a row a regression only when the ranges separate.
Afterwards read `scripts/agent/cpu-cap`'s log (`cpu-cap.log`): a pause of the bench or its instances during the run
invalidates it, so rerun. Put the numbers in `docs/perf/<previous>-to-<version>.md`.

The notes get a `## Faster` section only when the release is measurably faster: a short table of the rows that
moved (old, new, change) and one sentence naming the biggest win. A release that's the same within noise has no
Faster section. (0.2.28 and 0.2.29 were also timed against 0.2.17, the last CEF release, with
`scripts/release-compare-0.2.17.sh`, now in git history: `docs/perf/README.md`.)

### 4d. Settings native host harnesses (stable only)

Run every Settings native host harness before publishing a stable release; this step is optional for nightly:

```bash
scripts/agent/host-harnesses
```

The runner builds SolaraKit once in native/SolaraKit/.build (the one swift test uses), runs all seven harnesses with
separate scratch directories and logs under the clone's .hill/host-harnesses (reused by every run), and must print PASS for every harness and exit 0. A failure or timeout blocks stable
publication; fix it and rerun. The default whole-run deadline is 540 seconds (`--deadline SECS`, always under ten
minutes). `--only` is for focused checks; the stable gate requires the full run.

## 5. Publish

Both channels publish with `publish.sh` (`docs/releasing.md` › Cutting a release, step 4), to the identity's
`AC_RELEASE_REPO`. It merges the appcast onto the published feed, creates the release (a stable as latest) with the
DMG, zip, appcast and CLI tarball, and checks `releases/latest/download/appcast.xml` lists the version. It holds the
`release-lock` branch while it publishes, so it refuses to run alongside another publish, naming the holder;
`--break-lock` clears a lock older than 2 h left by a publish that died. Run it from the repo root:

```bash
git tag v<version> && git push origin main v<version>
.claude/skills/release/scripts/publish.sh <version> --dry-run
.claude/skills/release/scripts/publish.sh <version>
.claude/skills/release/scripts/feed.sh <version>
```

When engine/ changed since the last prebuilt engine, release.sh also packed `SolaraCore-<tree>.tar.xz` (the command
above uploads it, with `SolaraCore-<tree>-source.tar.xz` for a Helium engine) and wrote its table line. Every release's
notes end with a Source section linking its tag, so never delete or move a published tag
(`docs/releasing.md` › Source and licenses). Once the release is up, commit that line, so builds without a Chromium tree
find it (`packages/solaracore/scripts/fetch-engine.sh`):

```bash
if [ -f dist/<version>/prebuilt-engine.tsv ]; then
  cat dist/<version>/prebuilt-engine.tsv >> packages/solaracore/prebuilt-engines.tsv
  git add packages/solaracore/prebuilt-engines.tsv && git commit -m "Prebuilt engine: <version>'s" && git push origin main
fi
```

`appcast-merge.sh` puts this release's item onto the feed as it's published right now, so nightlies that shipped while
this release was being tested stay listed (it rewrites `dist/<version>/appcast.xml`, keeping `appcast.built.xml`).
Both must show the new version. feed.sh reads the URL from the built Info.plist, so it checks what this build will
poll.

### 5b. Staged rollout (an SolaraCore-sized or risky release)

Three steps, in this order. Nothing here publishes by itself; each needs the owner's go-ahead (the first is the standing
rule that a release which changes the engine or something users would notice publishes only after the owner has tested
the final RC and said ship).

1. **The owner tests the RC first.** Build `scripts/release.sh <version> --rc`, hand it over, and wait for "ship". Not
   for a JS-only fix that passed the smoke test.
2. **Phased appcast.** Build the release with `scripts/release.sh <version> --phased 86400`. The new appcast item then
   carries `<sparkle:phasedRolloutInterval>86400</sparkle:phasedRolloutInterval>` (check with
   `grep -c phasedRolloutInterval dist/<version>/appcast.xml`, which must print 1): Sparkle gives each copy a random
   group on that Mac (no ID, nothing sent) and offers the update to the first seventh of copies at once, a seventh more
   every interval, so everyone has it after a week. Someone who clicks Check for Updates… gets it at once. Publish as in
   step 5 and watch a day or two: Solara sends no telemetry, so that means `crash.log` and the owner's reports. A
   problem found: publish a fixed build with a higher build number: copies that haven't updated yet go straight to it.
3. **Everyone.** Remove the interval from the published appcast, so every copy sees the update:
   ```bash
   .claude/skills/release/scripts/rollout-everyone.sh <version> --dry-run   # the diff it would upload
   .claude/skills/release/scripts/rollout-everyone.sh <version>
   ```
   It holds the publish lock (`release-lock`, the same one `publish.sh` takes), so a nightly published meanwhile can't
   be overwritten. It edits the feed on the latest stable release as it is at that moment (`appcast.xml`), drops the
   interval from `<version>`'s item only, uploads it and checks what GitHub serves. (The appcast isn't signed as a whole, only its zip's `edSignature`, so editing the line keeps it
   valid.) The next release's `release.sh` starts from this published appcast, so it doesn't bring the interval back.

A release without `--phased` goes to everyone at once, as before.

## 6. README

The README's "Getting it" section says no release is published yet. With the first release, replace that sentence
with the download link (`https://github.com/<AC_RELEASE_REPO>/releases/latest`) and commit it. After that it needs no
change per release.

## 7. Report

Tell the user, briefly: the version and headline, what's in it (from the notes), the smoke result (N/N), that it's
live (release URL, appcast), how to get it (Check for Updates…), anything not verified (real trackpad/mouse input,
notarization), and what they need to try by hand.

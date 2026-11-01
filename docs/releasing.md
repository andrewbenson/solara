# Releasing

Releases are GitHub releases of `andrewbenson/solara` (the identity's `AC_RELEASE_REPO`), tagged `v<version>`, on two
channels: **stable** (`0.1.2`, a full release) and **nightly** (`0.1.3-nightly.1`, a GitHub prerelease: one fix,
shipped the day it's made; "Channels" below). Solara builds and publishes from this Mac with `scripts/release.sh` and
the release skill's `publish.sh`. Each release has these assets:

- `<Product>-<version>.dmg` (`Solara-0.1.1.dmg`): what people download (the app and an `/Applications` link, in a window with a
  poster behind them: `scripts/dmg`, where `render.sh` redraws the picture and `layout.sh` the layout).
- `<Product>-<version>.zip`: the archive Sparkle installs updates from.
- `solara-cli-<version>-macos-arm64.tar.gz` and its `.sha256`: the `solara` command (`docs/cli.md`).
- `appcast.xml`: the Sparkle feed, both channels' items in one file. The latest stable release's appcast is the feed
  (a nightly rewrites that asset; "Channels" below). Solara polls it straight from GitHub (`AC_FEED_URL`).
- `SolaraCore-<engine tree>.tar.xz`, only in a release built locally from a Chromium tree whose `engine/` changed since
  the last one: the release's engine (Chrome's framework, stripped), so the app builds without a Chromium tree. An engine
  published on its own goes to a prerelease instead, `engine-<engine tree:12>` ("Engines" below). `packages/solaracore/prebuilt-engines.tsv` maps
  `engine/`'s git tree to the release and the archive's SHA-256; `packages/solaracore/scripts/fetch-engine.sh` downloads
  it (the app's build runs it when there's no local engine build).
- `SolaraCore-<engine tree>-source.tar.xz`, with that archive when the engine is built on Helium (release.sh finds
  Helium's code in the framework): copies of the GitHub tags `engine/patches/build/env.sh` pins that aren't in this
  repo (`scripts/engine-source.sh`), and where Chromium's source is. See "Source and licenses" below.

Each version's notes are a file in the repo, `docs/release-notes/<version>.md` (how to write one:
`docs/release-notes/README.md`). The GitHub release and the update dialog come from it. The first
launch after an update opens `AC_NOTES_URL` in a new tab (`apps/browser/src/lib/releaseNotesPage.ts`): Solara's GitHub
releases page.

## Channels

Solara is one app with two Sparkle channels. A stable item in the appcast has no channel; a nightly item carries
`<sparkle:channel>nightly</sparkle:channel>` (`generate_appcast --channel nightly`). Sparkle skips items on a channel the
app doesn't allow, and allows none by default, so every shipped build (all on Sparkle 2.9.6, which has channels) and
every copy on Stable sees only stable items. A copy on Nightly allows `nightly` (`allowedChannels(for:)` in
`packages/shell/ios/Updater.swift`) and so gets the newest of both.

- **Which channel a copy is on.** Settings › General › "Update channel" (Stable / Nightly), kept in the defaults key
  `ACUpdateChannel`. Until the user picks, it's the channel of the build that first ran: the `ACUpdateChannel` key in
  `Info.plist`, which `release.sh --channel nightly` sets to `nightly` (the build setting `AC_UPDATE_CHANNEL`). It's
  written at the first launch, so a nightly copy stays on Nightly after it updates to a stable build. Switching to
  Stable never downgrades: Sparkle only offers a higher build number, so the copy waits for the next stable.
- **Versions.** Owner-only releases start at **0.0.1**, then 0.0.2, 0.0.3: add 0.0.1 per release.
  All 0.0.x builds use unsigned mode (ad hoc code signing, no Developer ID or notarization).
  **0.1.0 is the first Developer ID signed and notarized release**, once the owner has a personal Apple account.
  `CURRENT_PROJECT_VERSION` never resets: the previous floor is 81, so 0.0.1 must be **82 or higher**, and every
  subsequent release must exceed all previously shipped builds, including nightlies. Sparkle compares this integer,
  not the displayed version. For example: 0.0.1 (82), 0.0.2 (83), then 0.1.0 (84 or higher).
  `release.sh` refuses builds at or below 81 and at or below the newest build in the feed. A nightly still uses
  `<next stable>-nightly.<n>`; build numbers order its iterations. Owner-only 0.0.x releases normally use stable.
- **What an unsigned 0.0.x build gives up.** An ad hoc signature's designated requirement is its cdhash, so it
  changes with every build:
  - Chrome runs on the mock keychain (`ChromeUsesRealKeychain()` in `SolaraCoreHost.mm` is true only for a
    team-signed build), so "Solara Safe Storage" is never read or written and saved passwords, cookies and cards
    are mock-keyed. A later Developer ID build moves them with the Safe Storage re-key (`docs/testing.md` › Safe Storage re-key).
  - Three things still use the real login keychain: Connected Accounts secrets (`packages/shell/ios/Keychain.swift`),
    the sync key store (`packages/sync/ios/SyncModule.swift`, `KeychainKeyStore`) and the import of another browser's
    Safe Storage key. Their items are tied to the build that made them, so after each 0.0.x update macOS will likely
    ask once per item before the new build can read it.
  - TCC grants (camera, microphone, screen recording, Accessibility) are per signature and reset with each update.
  - The provisioning-only entitlements are left out: `com.apple.developer.web-browser.public-key-credential` (so no
    passkeys as a browser) and `keychain-access-groups` (Chrome's unexportable keys fall back). The app launches
    cleanly without them.
  - Test switches are honoured: `TestBuild()` means "not team-signed", so a 0.0.x build accepts the env-var test
    switches, including `SOLARA_TEST_REAUTH=granted`, which skips the password re-auth. Low risk, since whoever can
    set the app's environment already controls the account and 0.0.x is owner-only; it goes away at 0.1.0
    (backlog: key test switches off a build setting).
- **The feed.** Every build reads it at `AC_FEED_URL`, `releases/latest/download/appcast.xml`, and GitHub's "latest" skips prereleases, so it's always the newest stable
  release's `appcast.xml`. A stable release publishes the merged feed as its own asset and becomes latest; a nightly
  re-uploads the merged feed onto that same latest stable release (`gh release upload … --clobber`). The URL never
  changes. Both flows build on the published feed (`release.sh` fetches it and refuses to go on without it), and
  `appcast-merge.sh` puts the new item onto the feed as published at that moment, so a nightly that shipped while a
  stable was being tested isn't dropped. `generate_appcast` keeps 3 items per channel.
- **Downloads.** Stable keeps its versioned link (`releases/latest/download/<Product>-<version>.dmg`). The nightly has
  one fixed link, the `nightly` prerelease's `<Product>-Nightly.dmg` (`releases/download/nightly/<Product>-Nightly.dmg`),
  which each nightly re-uploads.
- **Proof.** `.claude/skills/release/scripts/channel-test.sh dist/<stable>/export/Solara.app` runs that build's own
  Sparkle against local feeds made by `generate_appcast`: on stable it isn't offered a nightly, and with a newer
  nightly in the feed it takes the stable; on nightly it takes the nightly, a newer stable, and the newest of both. It
  also checks the build-number order with Sparkle's comparator. `update-test.sh` does the stable-ignores-it half for
  every nightly's own item.

## Source and licenses

Every binary we publish (DMG, zip, engine archive) has its source next to it, and keeps it for as long as the binary
stays up. That's GPL-3.0 §6(d) for the GPL parts (uBlock Origin today), and it's how we work anyway.

- Every release's notes end with a Source section (`release.sh` writes it). It links the tag's tree: the app, the
  engine's patches, `gn_defines.sh`, the step scripts and this release flow. Once the engine is built on Helium, it
  also links the `SolaraCore-<tree>-source.tar.xz` asset of the release that carries that engine (the `v<version>` that first shipped it, or its `engine-<tree:12>` prerelease)
  (`packages/solaracore/prebuilt-engines.tsv`); `release.sh` refuses such an engine when it can't name that release.
- The `nightly` release's body names the nightly its `<Product>-Nightly.dmg` is and links that release
  (`publish.sh` rewrites it each time).
- Never delete or move a `v*` tag, or a release's source asset, while its release is up. A release can come down;
  its tag stays.
- About Solara and Settings › Advanced › "Source and licenses" link the running version's tag. The app carries
  `LICENSE*` and `NOTICE` in `Contents/Resources/Licenses`.

## Unsigned owner releases

The primary switch is `SOLARA_RELEASE_UNSIGNED=1`, used consistently by `release.sh`, `smoke.sh`, `update-test.sh`,
`channel-test.sh` and `publish.sh`. `release.sh --unsigned` is a convenience for that invocation only: export the
variable when running the whole workflow. A stable unsigned version must be 0.0.x (starting at 0.0.1); signed mode
refuses all 0.0.x, including nightlies. Neither mode can silently ship the other kind.

```bash
export SOLARA_RELEASE_UNSIGNED=1
APPCAST_BASE=none scripts/release.sh 0.0.1
.claude/skills/release/scripts/smoke.sh 0.0.1 none
.claude/skills/release/scripts/publish.sh 0.0.1 --dry-run
```

Bump the project version/build and commit release notes first, as below. For later releases omit `APPCAST_BASE=none`
and pass the previous version to smoke. The export uses ad hoc signatures throughout, including Sparkle's helpers;
retains hardened runtime and supported app/helper entitlements, adds the library-validation exception needed to load
ad hoc embedded libraries, and omits provisioning-only entitlements (keychain
access groups, application/team identifiers and iCloud passkeys). It verifies the sealed app strictly before and after
its check run. Gatekeeper/notary expectations become ad hoc + strict verification and archive EdDSA verification,
not a waived signature gate. The DMG has an EdDSA signature sidecar; the appcast's ZIP enclosure has `edSignature`.
The XML feed itself has no detached signature in Sparkle's current format.

Keep `AC_PUBLIC_ED_KEY` and its private key unchanged. Missing or mismatched EdDSA credentials must fail. Use
`SPARKLE_KEY_FILE` on the signing Mac; do not paste keys into commands or logs. Hill Studio can run `--phase build`
without that key. The separate, light signing step for the local proof is below; it does not rebuild the app or DMG.
Owner-only describes the audience, not access control: a public GitHub release remains publicly downloadable.

## Once per machine

Developer ID and notarization setup below applies to signed 0.1.0 and later. Unsigned 0.0.x needs the engine,
Pods and Sparkle signing key (on the signing Mac), with no Apple identity or notary credentials.

- The identity's **Developer ID Application** certificate (team `AC_TEAM_ID`: `33W8BDN775`) in the login keychain, and Xcode signed in to the team: the export fetches the Developer ID provisioning profile
  (`-allowProvisioningUpdates`) that the keychain-group entitlements need.
- The **Sparkle EdDSA key**, a login keychain item (service `https://sparkle-project.org`, account
  `AC_SPARKLE_ACCOUNT`: `solara`; `SPARKLE_ACCOUNT` overrides). Its public half is `SUPublicEDKey` in
  `apps/browser/macos/Solara-macOS/Info.plist`. Every update must be signed with it, so keep a backup:
  `apps/browser/macos/Pods/Sparkle/bin/generate_keys --account <account> -x <file>` exports it, and `-f <file>`
  imports it on another machine.
- For notarization, an App Store Connect API key (Team Keys, Developer role). Keep `AuthKey_<id>.p8`
  outside the repo (e.g. `~/.private_keys/`, mode 600) and point `scripts/.notary.env` (untracked) at it:
  `NOTARY_KEY=<path>`, `NOTARY_KEY_ID=<id>`, `NOTARY_ISSUER=<issuer id>`. release.sh prefers it to the
  keychain profile below, which notarytool keeps in the data-protection keychain: that reads as
  missing while the screen is locked. Otherwise, a notarytool profile named `solara`:
  `xcrun notarytool store-credentials solara --apple-id <id> --team-id 33W8BDN775` (it asks for an
  app-specific password). Signed mode refuses missing credentials unless `ALLOW_UNNOTARIZED=1` is explicitly set for an experiment;
  that override is not a notarized release.
- The engine: SolaraCore's `Chromium Framework.framework` built in `~/chromium-build` (`scripts/agent/engine-build`;
  `docs/engine-build.md`), and `pod install` in `apps/browser/macos`. A framework built elsewhere goes in through
  `SOLARACORE_FRAMEWORK`. That skips the tree checks and ships no engine archive, unless `SOLARACORE_FRAMEWORK_ENGINE`
  names the `engine/` git tree it was built from (`git rev-parse HEAD:engine`, checked against HEAD). Then the
  release packs that engine, and its source when it's Helium, as a build from the tree would.

## Cutting a release

1. Bump `MARKETING_VERSION` (the version) and `CURRENT_PROJECT_VERSION` (the build number, which Sparkle
   compares: it must exceed 81 and go up every release) in both configurations of the `Solara-macOS` target in
   `apps/browser/macos/Solara.xcodeproj`. The helpers and the Dock tile plug-in take the same values.
2. Write `docs/release-notes/<version>.md` from `git log v<previous>..HEAD` (`docs/release-notes/README.md`; for the
   first release, "The first release" below).
3. Commit both ("Release <version>" or "Nightly <version>") and run `scripts/release.sh <version>` (`--channel nightly`
   for a nightly). It stops right away if the notes file is missing or lacks its `date` and
   `headline`, if the tree under `apps/browser`, `packages`, `engine` or `scripts/dmg` has uncommitted changes, or if the engine
   framework is older than the tree's SolaraCore sources or the Chromium tree differs from `engine/solaracore`
   (`apply.sh --check`), if the version doesn't fit the channel or the notes' `channel`, if it can't read the published
   appcast, or if the build number isn't above every build in it. It writes `dist/<version>/`:
   - archives the Release configuration of `apps/browser/macos` for arm64, staging the engine into its own derived
     data so a development build restaging can't change it mid-build, and exports it ad hoc in unsigned mode or with Developer ID in signed mode. The signed export is Xcode's
     (`-allowProvisioningUpdates`, which needs Xcode signed in to the team); with `RELEASE_PROVISIONING_PROFILE` set
     the archive is signed ad hoc (`AdHoc.xcconfig`) and `scripts/lib/export-developer-id.sh` does the export: it embeds
     that profile and re-signs inside out with Developer ID, the same identifiers, entitlements, flags and designated
     requirements Xcode's export gives (`xcodebuild -exportArchive` refuses an Xcode-managed profile with manual signing),
   - leaves out what Solara never loads (`packages/solaracore/scripts/prune-bundle.sh`, after `strip-engine.sh`): Chrome's
     locales other than English and the app's own languages (Chrome takes its locale from the app bundle's
     localizations, and Solara has none, so it runs in en-US whatever the Mac's language), SwiftShader and its Vulkan
     loader (WebGL and WebGPU run on Metal; Chrome dropped SwiftShader's WebGL fallback), Chrome's first-run sounds
     and pictures inside `resources.pak` (blanked by hash, `first-run-resources.sha256`; Solara always passes
     `--no-first-run`), uBlock Origin's other locales, React Native's `@3x` images (Macs draw at 1x or 2x) and hermes's
     local symbols. Each step has a kill switch: `SOLARA_PRUNE_LOCALES`, `SOLARA_PRUNE_SWIFTSHADER`,
     `SOLARA_PRUNE_FIRST_RUN`, `SOLARA_PRUNE_UBO_LOCALES`, `SOLARA_PRUNE_RN_3X`, `SOLARA_STRIP_HERMES` (or `SOLARA_PRUNE` for
     all) set to `off`. Chrome's opt-in software GPU modes are unsupported in a release build: with
     `--use-angle=swiftshader`, `--enable-unsafe-swiftshader --disable-gpu` or WebGPU's
     `requestAdapter({forceFallbackAdapter: true})` under `--enable-unsafe-webgpu`, WebGL and WebGPU are unavailable
     (chrome://gpu says Disabled, the adapter is null) while pages, video and the GPU process carry on, with no crash or
     restart. The prebuilt engine archive is packed from a copy taken before pruning, so a checkout that fetches it
     gets every locale, SwiftShader and the first-run resources, and the kill switches work there too,
   - signs Chrome's framework inside out as Chrome signs its own (`chrome/installer/mac/signing/parts.py`): the
     helpers under the hardened runtime with library validation, except the renderer and GPU ones (Aperitif's too),
     which get `allow-jit` (`packages/solaracore/scripts/signing`) instead; then the framework, then the app again with
     the entitlements the export gave it,
   - checks what an in-place update depends on: the identity's bundle id (`com.hill.solara`), executable `Solara`, the
     designated requirement (the identity's team), the keychain groups, Sparkle's feed and key and the usage strings in
     `Info.plist`; that every piece of code is Developer ID with a timestamp and no `get-task-allow`; and that the app
     is signed with `com.apple.developer.web-browser.public-key-credential` exactly when its provisioning profile
     grants it. Apple hasn't granted it yet; once it has, a `RELEASE_PROVISIONING_PROFILE` downloaded again carries it
     and the export signs with `Solara-ICloudPasskeys.entitlements` on its own (the Xcode-managed export still needs
     `CODE_SIGN_ENTITLEMENTS` switched to that file),
   - launches the app once in the background (throwaway data dir), waits for uBlock's rulesets to be indexed,
     quits it and checks the signature again: the app must never write into its own bundle,
   - in signed mode, notarizes and staples the app and the DMG,
   - packages the DMG (lzma in 4 MB chunks, `udif-chunk-size=8192`, hdiutil's largest; `SOLARA_DMG_CHUNK=off` goes back
     to its 1 MB default) and the zip, and EdDSA-signs the archives (`generate_appcast` names the feed after the app's
     `SUFeedURL`, so release.sh passes it `-o`) with the Sparkle key. It starts from the
     published appcast, so earlier versions and the other channel's items stay listed; a nightly's item gets
     `<sparkle:channel>nightly</sparkle:channel>`. The new item embeds the notes' headline and body
     (Markdown, shown in Sparkle's update dialog) and links the page as its full release notes
     (`sparkle:fullReleaseNotesLink`: "You're up to date" › Version History opens it in a tab),
   - copies `LICENSE*` and `NOTICE` into `Contents/Resources/Licenses` before signing, and checks they're there,
   - writes `release-notes.md` (the notes' body, then the standard Install and Source sections) and
     `provenance.txt` (the commit and the engine build it shipped).

   `scripts/release.sh <version> --rc` builds a candidate into `dist/<version>-rc/` from the working tree, as
   `<version>` with the next build number, notarized but never published: no notes file or clean tree needed (it
   lists the uncommitted files it included).
4. Tag and publish: `git tag v<version> && git push origin main v<version>`,
   then `.claude/skills/release/scripts/publish.sh <version>` (`--dry-run` prints what it would do). It reads the repo and the product from the identity, merges the
   appcast onto the feed as published right now (`appcast-merge.sh`), creates the release (a stable one as latest, a
   nightly as a prerelease that's never latest) with the DMG, zip, appcast, CLI tarball and a local engine archive,
   and checks the feed lists the version on GitHub. A nightly also re-uploads the merged feed onto the
   latest stable release and `<Product>-Nightly.dmg` onto the `nightly` release. With an engine packed here, append
   `dist/<version>/prebuilt-engine.tsv` to `packages/solaracore/prebuilt-engines.tsv` and commit it.

Before publishing, run the smoke test: `.claude/skills/release/scripts/smoke.sh <version> <previous> [--rc]` (the
`release` skill runs the whole flow). Besides the hidden launch over CDP, it checks the update itself against
`dist/<previous>/export`: the identity Sparkle, the keychain and TCC compare (bundle id, executable, feed, key, the
previous build's designated requirement, a higher build number), the appcast's EdDSA signature of the zip, Gatekeeper
on the app and the DMG, Sparkle actually updating a copy of the previous build (`update-test.sh`) and the previous
build's data opening in the new one (`carryover.sh`). By hand, check the build the way the script can't: launch
`dist/<version>/export/Solara.app` with `SOLARA_BACKGROUND=1`, a throwaway `SOLARA_DATA_DIR` and
`SOLARA_REMOTE_DEBUGGING_PORT`, and load a page over CDP. Afterwards `codesign --verify --deep --strict` must still
pass on it.

To check the after-update tab too: in that data dir, set `lastVersion` in `release-notes.json` to the
previous version (`{"version":1,"lastVersion":"<previous>","pending":null}`) and relaunch with
`SOLARA_RELEASE_NOTES=1` added (test instances skip the tab without it). `curl localhost:<port>/json` must
list one `…/release-notes#<version>` page; a second launch opens none.

## The app's identity

Everything that names the app comes from one file, `apps/browser/macos/Identity.xcconfig`. It's the base
configuration of the project (not the target's, so `pod install` never touches it).

| Setting | Read by | Value |
|---|---|---|
| `AC_PRODUCT_NAME` | `CFBundleName`, `CFBundleDisplayName`, the DMG's app and volume, the update zip, keychain items and the iCloud sync folder the app itself names, the CLI's command (lowercased) and install home | `Solara` |
| `AC_TEAM_ID` | `DEVELOPMENT_TEAM`, the export, release.sh's signing identity and checks | `33W8BDN775` |
| `AC_BUNDLE_ID` | `PRODUCT_BUNDLE_IDENTIFIER` (so the data folders, the defaults and the keychain groups), release.sh's checks, the data dir the CLI connects to | `com.hill.solara` |
| `AC_FEED_URL` | `SUFeedURL` | `https://github.com/andrewbenson/solara/releases/latest/download/appcast.xml` |
| `AC_PUBLIC_ED_KEY` | `SUPublicEDKey`, checked against the Sparkle key release.sh signs with | Solara's key |
| `AC_SPARKLE_ACCOUNT` | the keychain account release.sh finds the Sparkle key under | `solara` |
| `AC_RELEASE_REPO` | release.sh and the release skill's scripts (`gh`, the feed, download URLs, the Source line), About's and Settings' source links, Send Feedback, where the CLI's installer downloads, where `fetch-engine.sh` and `publish-engine.sh` find prebuilt engines | `andrewbenson/solara` |
| `AC_NOTES_URL` | the page opened after an update, Help › Release Notes, the appcast's notes link | `https://github.com/andrewbenson/solara/releases` |
| `AC_SWITCHES_URL` | the kill-switch file read at launch; empty never fetches, so every switch stays on | empty |
| `AC_APP_ICON` | `ASSETCATALOG_COMPILER_APPICON_NAME`, so the `.appiconset` in `Assets.xcassets` that becomes the bundle's icon (`CFBundleIconName`, `<name>.icns`), the DMG's volume icon and the Dock tile plug-in's artwork. Any other name than `AppIcon` also hides Settings › Appearance › App Icon, and the in-app copy of the icon (onboarding, What's New, the check-in banner) comes from `apps/browser/src/lib/appIcon.ts`, keyed by `AC_PRODUCT_NAME` | `SolaraIcon` (the Outrun synthwave sun, `docs/brand/solara`) |

`PRODUCT_NAME` is `$(AC_PRODUCT_NAME)`, so the bundle (`Solara.app` in `dist/<v>/export/`), its executable and the dSYM
are named after the product. Scripts take the name from the identity (`scripts/identity.sh`, `scripts/lib/identity.mjs`)
or from a bundle's `CFBundleExecutable`. The release assets are named for the product too (`Solara-<version>.dmg`,
`Solara-Nightly.dmg`).

release.sh bakes the product, bundle id and repo into the CLI tarball (`solara-cli-<version>-macos-arm64.tar.gz`, same
name in every build) and pins its digest into the app; the app's installer passes its own product and repo. So the
app installs `~/.local/bin/solara` into `~/Library/Application Support/Solara/CLI`, downloads from
`andrewbenson/solara`'s releases and drives `~/Library/Application Support/com.hill.solara`. The tarball must be
uploaded to the same release as the app: `publish.sh` reads the repo from the identity.

The Sparkle key was generated on 2026-10-24 (account `solara` in the login keychain, public half in
`AC_PUBLIC_ED_KEY`); release.sh refuses to sign with a key whose public half isn't `AC_PUBLIC_ED_KEY`. An xcconfig
reads `//` as the start of a comment, so a value that contains `//` is written with `/$()/`, as the URLs are. Check
what the identity resolves to:
`xcodebuild -showBuildSettings -project apps/browser/macos/Solara.xcodeproj -target Solara-macOS -configuration Release | grep ' AC_'`.

Once per release machine:

1. Apple: the team's **Developer ID Application** certificate in the login keychain (release.sh takes the identity whose
   name ends in `(<team id>)`), and Xcode signed in to the team. The App ID `<bundle id>` has a Developer ID
   provisioning profile that allows the keychain groups `<team id>.<bundle id>.webauthn`, `.unexportable-keys`
   and `.secure-payment-confirmation` (`Solara.entitlements`); the export fetches it with `-allowProvisioningUpdates`,
   and release.sh stops without an `embedded.provisionprofile`.
2. Notarization: an App Store Connect API key for the team in `scripts/.notary.env`, or a notarytool profile
   (`NOTARY_PROFILE=<profile>`), as in "Once per machine".
3. The DMG's layout positions icons by name: `scripts/dmg/DS_Store-Solara`, made by `scripts/dmg/layout.sh Solara`.
   Releases require `scripts/dmg/DS_Store-$product_name`; there is no generic layout fallback, and a missing layout stops packaging.

The engine compiles in the same identity (`docs/engine-build.md` › "The engine's identity"): the keychain groups'
bundle and team id and the "Solara Safe Storage" item. Prebuilt engines come only from Solara's own releases
(`prebuilt-engines.tsv`, appended by `publish-engine.sh` or a release that packed one).

## The first release

Solara's first release is a stable unsigned one, **0.0.1 (build 82 or higher)**: the feed lives on the latest stable release
(`releases/latest/download/appcast.xml`), so there's nothing for a nightly to join until it exists, and `publish.sh`
refuses a nightly while the repo has no stable release. With no `v*` tag yet:

- **Notes** come from every commit since the code Solara began from, not from a tag:
  `git log --no-merges main --not c508a9f33566 -- apps/browser packages engine` (c508a9f33566 is the last commit
  Solara took from the code it began from; those commits aren't listed).
- **The feed** has nothing to build on: `SOLARA_RELEASE_UNSIGNED=1 APPCAST_BASE=none scripts/release.sh 0.0.1` starts a new one, and `publish.sh`
  sees no release yet and publishes this one's appcast as the feed.
- **The smoke test** has no earlier export: `SOLARA_RELEASE_UNSIGNED=1 .claude/skills/release/scripts/smoke.sh 0.0.1 none` skips the update test, carryover and the
  same-identity checks, and runs every launch check. For this unsigned bootstrap it authenticates the local
  appcast/ZIP and configured HTTPS feed URL; publish checks the hosted feed once it exists.
- **The perf gate** has no earlier stable to time against. The perf ratchet runs as always (its ceilings are absolute);
  native-bench and js-bench run once on 0.0.1 alone and their numbers go in `docs/perf/0.0.1-baseline.md`, which the
  next stable is gated against together with 0.0.1's own export. Run the local self-update proof below before shipping
  0.0.1: smoke with `none` alone cannot establish that it can update.

## Local self-update proof (Hill Studio and the signing Mac)

Run this on Hill Studio before publishing 0.0.1, from a disposable patched checkout with dependencies, Pods and the
engine already available. These commands intentionally change that checkout's project versions. Nothing installs in
`/Applications`. The terminal running the proof must already have Accessibility permission: the driver presses only
English Sparkle install/relaunch buttons belonging to the exact scratch app PID, without activating it.

### Hill Studio: build

```bash
export SOLARA_RELEASE_UNSIGNED=1 APPCAST_BASE=none
python3 - <<'PYBUILD'
from pathlib import Path
import re, subprocess
p = Path('apps/browser/macos/Solara.xcodeproj/project.pbxproj')
for version, build in [('0.0.1', 82), ('0.0.2', 83)]:
    s = re.sub(r'MARKETING_VERSION = [^;]+;', f'MARKETING_VERSION = {version};', p.read_text())
    s = re.sub(r'CURRENT_PROJECT_VERSION = [^;]+;', f'CURRENT_PROJECT_VERSION = {build};', s)
    p.write_text(s)
    subprocess.run(['scripts/release.sh', version, '--unsigned', '--rc', '--phase', 'build'], check=True)
PYBUILD
proof="$PWD/.hill/unsigned-self-update-proof"
.claude/skills/release/scripts/self-update-proof.sh prepare \
  "$PWD/dist/0.0.1-rc/Solara.xcarchive/Products/Applications/Solara.app" \
  "$PWD/dist/0.0.2-rc/Solara.xcarchive/Products/Applications/Solara.app" "$proof"
rsync -a "$proof/feed/" "${OWNER_MAC:?set the signing Mac SSH target}:solara-unsigned-proof-feed/"
```

The two archives are separate Release builds. `prepare` exports them ad hoc with the normal unsigned signing helper,
then changes only scratch fixture plists: a shared test bundle id, loopback feed, scratch home/data and hidden relaunch
environment. The candidate is labeled **0.0.2-test**, build **83**; it is not a publishable stable version. Both retain
`AC_PUBLIC_ED_KEY`. Use a fresh `proof` directory for every attempt. If 82/83 are already in use, choose a higher pair.

### Owner's Mac: sign (light)

Use the same patched checkout and Sparkle 2.9.6 `bin` tools. Set `SPARKLE_KEY_FILE` to the existing exported release key
and `SPARKLE_BIN` to that distribution's `bin` directory. No app build, Developer ID, notary or keychain is needed.

```bash
SPARKLE_KEY_FILE="${SPARKLE_KEY_FILE:?set the existing release key file}" \
SPARKLE_BIN="${SPARKLE_BIN:?set the Sparkle 2.9.6 bin directory}" \
  .claude/skills/release/scripts/self-update-proof.sh sign "$HOME/solara-unsigned-proof-feed"
```

This signs the exact ZIP and verifies it against `AC_PUBLIC_ED_KEY`, then writes `appcast.xml` with its `edSignature`.
The feed is not signed as a whole. Return only that XML; do not repack or modify the ZIP. The `run` step also accepts
an already-signed appcast/ZIP pair at these paths and never needs the private key.

### Hill Studio: serve + install + update + verify

```bash
proof="$PWD/.hill/unsigned-self-update-proof"
rsync -a "${OWNER_MAC:?set the signing Mac SSH target}:solara-unsigned-proof-feed/appcast.xml" "$proof/feed/appcast.xml"
SOLARA_RELEASE_UNSIGNED=1 .claude/skills/release/scripts/self-update-proof.sh run "$proof"
```

`run` verifies the production-key archive signature, serves loopback only, launches scratch 0.0.1 hidden with
`perf-probe` and its own data/home, explicitly calls `checkForUpdates`, accepts Sparkle's install/relaunch choices,
and fails after 300 seconds if replacement/relaunch does not complete. It requires successful appcast and ZIP HTTP
requests, a new running PID at the same scratch app/executable path, preserved hidden/data environment, and the
running app's native `CFBundleVersion`/version/configuration: **83 / 0.0.2-test / Release**. It then strict-verifies the
installed ad hoc signature and compares the entire bundle to the candidate. It quits only that scratch app and stops
its server, retaining `proof.log`, `http.log`, `trigger.json`, `running.json` and `data/relaunched.json` as evidence.
No PASS means no proof: AX/button-label, LaunchServices environment, runtime/JIT or updater errors need investigation.

## Engines

Without a Chromium tree, the app's build links a prebuilt Chromium Framework. It's built here
(`docs/engine-build.md`); after building it, `scripts/publish-engine.sh` (`--dry-run` first) packs it as release.sh
packs one (stripped, unpruned) with its Helium source, uploads both to the prerelease `engine-<engine tree:12>` (never
latest, so the feed and the download links never move to it) and appends `<tree> engine-<tree:12> <sha256>` to
`packages/solaracore/prebuilt-engines.tsv`: commit and push that line. `fetch-engine.sh` stops at once when
`engine/`'s tree has no published engine, saying to build it.

## Keys from files and phases

`release.sh` can read its keys from files instead of Xcode's export and the login keychain:
`RELEASE_PROVISIONING_PROFILE`, `SPARKLE_KEY_FILE` and `NOTARY_KEY`/`NOTARY_KEY_ID`/`NOTARY_ISSUER`. Without `--phase`
it does everything in one go; `--phase build|sign|check` runs the build with no keys, then signing and packaging,
then the launch check once the keys are gone (`RELEASE_BUILD_INPUT` names the build the sign phase reads).

`publish.sh` and the staged-rollout step (`rollout-everyone.sh`, in the release skill) take one lock, the branch
`release-lock` (created atomically through GitHub's API, its commit message naming the holder and the time), before
they read the latest release and the feeds, and give it back on exit, so two publishes can't build on the same
snapshot. A second publish meanwhile stops, naming the holder; a lock older than 2 h (a publish that died) is broken
only with `--break-lock`, and only when its holder and time can be read. Dry runs take it too, and write nothing else;
`PUBLISH_LOCK` renames it for dry runs only.

## Sparkle 2.9.6: unsigned updates and 0.1.0

Both **ad hoc 0.0.1 → ad hoc 0.0.2** and **ad hoc 0.0.x → Developer ID 0.1.0** are supported with the same
EdDSA key: validation accepts EdDSA or a matching code signature, and independently validates the new app's code
signature when only EdDSA passes. Removing code signing or the public key is rejected.
[SUUpdateValidator.m, lines 252–346](https://github.com/sparkle-project/Sparkle/blob/2.9.6/Sparkle/SUUpdateValidator.m#L252)
implements this policy.

The code comparison copies the old designated requirement and checks the new bundle against it; it does not require
that comparison to pass when EdDSA passes. Ad hoc helpers have no team; Sparkle's XPC validator omits the team
requirement in that case, so the unsigned export re-signs Sparkle's tools too.
[SUCodeSigningVerifier.m, lines 23–156 and 417–431](https://github.com/sparkle-project/Sparkle/blob/2.9.6/Autoupdate/SUCodeSigningVerifier.m#L23).

For our full ZIP app updates, **no intermediate release or `SUVerifyUpdateBeforeExtraction` key is required**.
`AppInstaller` chooses pre-extraction validation when that key or the archive type requires it, and otherwise validates
after extraction. Setting the key to YES would also work with the unchanged EdDSA key; it is not a migration fix.
[AppInstaller.m, lines 252–294](https://github.com/sparkle-project/Sparkle/blob/2.9.6/Autoupdate/AppInstaller.m#L252).

Keep `com.hill.solara`, the executable name, `SUPublicEDKey`/`AC_PUBLIC_ED_KEY`, the feed and monotonically increasing
builds. Release 0.1.0 uses Developer ID + notarization, and its ZIP is still signed with that EdDSA key. Before shipping
it, repeat an in-place test from the final 0.0.x to the final signed export. Check macOS permission and data behavior
separately: passing Sparkle validation does not preserve an ad hoc app's macOS identity or mock-keychain secrets.

## Update checks

Keep the bundle id, executable, feed and EdDSA key stable. Within Developer ID releases also keep the team and
designated requirement stable to preserve macOS identity. The transition from ad hoc to Developer ID is supported
by Sparkle as described below, but macOS permissions may need approval again, and mock-keychain data from an ad hoc
build is not a promise of production keychain/passkey continuity. The new build
opens the old one's data where it is (`InstalledDataDirectory` in `packages/solaracore/ios/SolaraCoreHost.mm`:
Chrome's user data dir `~/Library/Application Support/<bundle id>/Chromium`, profiles `Default` and `Profile <id>`,
with the app's own documents, session and settings, in the folder above). Only Developer ID builds use the login
keychain and its "Solara Safe Storage" item, which trusts the app by its designated requirement; test instances
(`SOLARA_DATA_DIR` or `SOLARA_BACKGROUND`) and ad hoc builds use Chrome's mock keychain.

`carryover.sh` checks the data: the previous build makes two profiles with tabs, persistent and session cookies,
localStorage, saved passwords, bookmarks, history, an address, a site permission, a zoom level and an unpacked
extension, and the new build, started without `SOLARA_DATA_DIR`, must find and read all of it. Both run as test
copies (a test bundle id, signed ad hoc) in a fake home (`HOME` and `CFFIXED_USER_HOME`), so the real app's data,
defaults and keychain are never touched. `rollback.sh <previous app> <new app>` (not part of smoke.sh) checks going
back on the same setup: the previous build, then the new one adding a second session, then the previous one again
must show both sessions' data without crashing or resetting the profile.

`update-test.sh` runs Sparkle itself: the previous build's `Sparkle.framework` (through `sparkle-host.swift`) reads a
local feed made of the release appcast's own item, downloads the zip, checks its EdDSA signature, extracts it and runs
Sparkle's installer, which swaps a scratch copy of the previous build for the new one, silently and without
relaunching it. The copies get a test bundle id and a throwaway key, so neither the real defaults nor the release key
are involved; the real identity and signature are what smoke.sh's other update checks compare.

The framework keeps Chrome's name (`Chromium Framework`); its helpers are the product's (`Solara Helper (Renderer)`,
from `chromium-helper-name.patch`), as is the Alerts helper's display name. Their bundle ids and team are ours, and
the keychain and macOS permissions belong to the app itself. Their icon is Solara's (the Alerts helper's shows on
every notification): `engine/chromium` replaces Chromium's logo.

## Unnotarized builds

Owner-only 0.0.x releases are ad hoc and unnotarized. Signed 0.1.0 and later releases are notarized, with the App Store Connect API key in `scripts/.notary.env` or the notarytool profile `solara`
("Once per machine"). An Apple ID with `--apple-id … --team-id …` and an app-specific password also works, but locks
the Apple ID after repeated failures. If a build ever ships unnotarized, Gatekeeper refuses to open the download. Either open it once from System Settings › Privacy &
Security › Open Anyway, or run `xattr -dr com.apple.quarantine /Applications/Solara.app`.

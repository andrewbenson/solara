# Engine update plan: Chromium 156.0.8078.79 on Helium 0.20.3 (for 0.2.0)

Planned on 2026-11-02, from source only. Nothing has run in `~/chromium-build` yet. The procedure is
[engine-build.md](../engine-build.md) › Rebuilding › "Moving to a new Chromium version"; this note says what to expect
when it runs. The owner has approved the `gclient sync` and the full build for 0.2.0.

## Target

| Pin | Today | Target |
|---|---|---|
| `CHROMIUM_VERSION` | 156.0.8078.47 | 156.0.8078.79 |
| `CHROMIUM_COMMIT` | `1d17a2e2ee147bb7d6ae2ab6abdb3a2510c17775` | `a21ce95c24ce3964416f09ae1862f53f319eb4d0` |
| `HELIUM_TAG` (helium-chromium) | 0.20.1 (`f29a2596`) | 0.20.3 (`2f81b9cafa38a95071e20de3f9cd6b0aca6d3c65`), whose `chromium_version.txt` is 156.0.8078.79 |
| `HELIUM_MACOS_TAG` | 0.20.1.1 (`9aa975a5`) | 0.20.3.1 (`0c7da2ba0b61a2143adf1c6d56ccd0df6a53d0bf`) |
| `SISO_VERSION` | `git_revision:dfc32e4e…` | unchanged unless 156.0.8078.79's DEPS needs a newer siso (check at step 1) |

Chromium has tagged up to 156.0.8078.90, but Helium's newest is 0.20.3 for .79. Step 3's `pins` stage refuses a tree whose
version differs from Helium's, so .79 is the target until Helium ships a newer tag. Between .47 and .79 there are 391
commits: 69 `[M156]` merges (fixes, among them a Blink use-after-free in `ImageCaptureFrameGrabber`), PGO profile rolls,
and DEPS, V8 and ANGLE rolls.

## What changed upstream

**Helium.** Both series are unchanged: no patch was added, removed or reordered, and `flags.gn`, `deps.ini`,
`domain_substitution.list` and the resources are untouched. 39 helium-chromium patches changed:
- Most only refresh their context for .73 and .79.
- `helium/core/add-native-bangs` reworked bang loading (a shared `BangCache`, retries with backoff, and a new
  `ShouldFetchBangs` gate on the services pref).
- Larger content changes in `disable-ai`, `fix-building-without-safebrowsing`, `remove-unused-preferences-fields`,
  `disable-autofill-download-manager`, `add-ipv6-probing-option`, `disable-gcm` and `disable-google-host-detection`.

helium-macos changed only its submodule pointer and the hunk headers of `sparkle2-integration` and
`macos/fix-disabling-safebrowsing`. Outside `patches/`, `utils/prune_binaries.py` and `devutils/update_lists.py`
changed (pruning paths).

**Skips and guards.** Every `SKIP` entry is still in the series:
- `fix-building-without-mdns-and-service-discovery` gained a `[[maybe_unused]]`; check that it is still a leaf.
- `sparkle2-integration` changed only a hunk header.
- `change-keychain-name` and `prevent-reset-on-keychain-unavailability` are unchanged.
- `modify-default-prefs` changed only a hunk header, so the `GUARD_ALLOWED` hit on `kCredentialsEnableService` should
  stand.
- Expect the `guard` stage to find the same four hits.

**Chromium.** Of the 357 files the 391 commits touch, four are files our series touches:

| File | Our step | Upstream change |
|---|---|---|
| `chrome/browser/BUILD.gn` | `chromium-helium-onboarding-off` | headless command-line fix |
| `chrome/browser/chrome_content_browser_client.cc` | layer `engine/solaracore` (hooks) | same headless fix |
| `chrome/browser/extensions/BUILD.gn` | `chromium-cef-carryover`, `chromium-extension-omaha-attributes`, `chromium-helium-ublock-off` | POR extension API on ChromeOS |
| `chrome/browser/renderer_context_menu/render_view_context_menu.cc` | `chromium-helium-context-menu-cast` | MenuSimplification: Partial Translate guards, duplicate Reading Mode entries |

## Which of our patches need work

`python3 engine/patches/series.py check` passes today (66 steps, 303 touched paths), so every change below comes from
upstream. The predictions come from the files each changed upstream patch touches against `series.py files`. The real
answer is `series.py check` and `apply.sh --check` on the new tree.

| Our patch | Expect | Why |
|---|---|---|
| `chromium-helium-bangs-off` | **rework** | It replaces the old `BangManager::LoadBangs` body, which no longer exists. Upstream now skips the fetch when `ShouldFetchBangs` is false, and our branding patch keeps `ShouldAccessServices` false, so the request we blocked shouldn't happen any more. Keep a short-circuit in the new `LoadBangs` anyway, as defence, and confirm in a hidden instance that nothing is requested. (Ardia's a55758e4 needed the same rework.) |
| `chromium-extension-omaha-attributes` | **rework likely** | Its six files overlap `fix-building-without-safebrowsing`'s changed hunks (`extension_service.{cc,h}`, `chrome_extension_system.cc`, `extension_registrar.cc`, `update_service.cc`, `extensions/BUILD.gn`) and Chromium's own `extensions/BUILD.gn` change. Ardia's a55758e4 needed this one too. |
| `chromium-helium-context-menu-cast` | rework possible | Chromium's MenuSimplification changes plus Helium's `degoogle-context-menu`, `simplify-context-menu` and `force-paste-action` all edit `render_view_context_menu.cc`. |
| `chromium-helium-branding`, `chromium-helium-services-page-off`, `chromium-helium-onboarding-off` | context refresh | `services_page.html`, `helium_services_helpers.{cc,h}`, `chrome_web_ui_configs.cc`, `generated_resources.grd` and `chrome/browser/BUILD.gn` moved under bangs, onboarding, disable-ai and noise changes. Branding's job is unchanged. Check that `ShouldAccessServices` still returns false and that `helium-check-build.py` passes. |
| `chromium-helium-ublock-off`, `chromium-cef-carryover` | context refresh | `extension_prefs.cc` and `extensions/BUILD.gn` |
| `chromium-notification-platform-bridge-hook` | context refresh | `browser_process_impl.cc`, `profile_impl.cc` and `profile_manager.cc` (disable-ai, remove-unused-preferences-fields) |
| `chromium-autofill-address-bubble-window` | context refresh | `save_card_bubble_controller_impl.cc` (remove-unused-preferences-fields) |
| `chromium-angle-metal-shader-cache`, `chromium-helper-name`, `chromium-solara-layer` | context refresh | `chrome/BUILD.gn` (prune fix) |
| `chromium-initial-document-access`, `chromium-thaw-live-connections` | context refresh | `web_contents_impl.cc`, `render_frame_host_impl.cc`, `content/browser/BUILD.gn` (noise, force-paste) |
| layer `engine/solaracore` (`apply.sh` hooks) | check | `chrome_content_browser_client.cc` (Chromium headless fix, five Helium patches), `browser_window_features.cc` (Helium layout), `browser_commands.cc` (force-paste) |
| everything else, Safe Storage included | none expected | no upstream change in its files |

Estimate: two reworks, one possible rework, about ten context refreshes, and a hook check. That's half a day of
engine work, done under the chromium lock between steps 3 and 5 with `series.py materialize` and `check`.

## Xcode 27.2 and the Metal Toolchain

This Mac has Xcode 27.2 (27B52), but its Metal Toolchain is **not installed**:
- `xcodebuild -showComponent MetalToolchain` reports build 27B47, uninstalled.
- `xcrun metal` fails with "missing Metal Toolchain".

The toolchain downloaded on 2026-10-25 (27A266a, in `~/chromium-build/logs/metal-toolchain.log`) belonged to the
previous Xcode. ANGLE compiles its Metal shaders with `metal`, so a full build fails without it. An incremental engine
build fails as soon as one of ANGLE's shader actions reruns.

Run `xcodebuild -downloadComponent MetalToolchain` (about 840 MB) before step 5, and check that `xcrun metal --version`
works. Do it again after every Xcode update. The build also moves to the macOS 27.2 SDK. `gn_defines.sh` already keeps
warnings from failing the build, but a new SDK can still break the build outright: a removed API or a module-map
change would fail it. Note any fix in `engine-build.md`.

## Cost

| Step | Time (M5 Pro, from the move to 156 on 2026-10-25) | Notes |
|---|---|---|
| Metal Toolchain download | ~10 min | once per Xcode version |
| 1. `01-sync.sh` | 10–40 min | Fetch the new tag at depth 1, then run `gclient sync --reset --force -D` with the PGO profiles. DEPS, V8, ANGLE and the mac-arm PGO profile all changed, so `gclient sync` is needed. Delete the git dep checkouts first: syncing took 3.5 min that way, against stalls when they were kept. |
| 3. Helium | ~3 min | `pins` with the new tags, then `guard` and the rest |
| 4. Our series | seconds, plus the patch work above | |
| 2. `gn gen` | 5 s | |
| 5. Full build | 2–2.5 h | Official build with ThinLTO and the new PGO profile; `out/` is deleted, so nothing is incremental. Measured in engine-build.md: 2.5 h on 2026-10-18, 2 h for 156 on 2026-10-25; AGENTS.md's "about 5 hours" is the conservative figure with sync and patch work |
| App build, acceptance, smoke | ~1 h | `build-app`, `packages/solaracore/scripts/acceptance.mjs`, release smoke |

That's about 3–3.5 hours of machine time, and 5–7 hours of wall time with the patch work. It's the one heavy job on
this Mac for that stretch, so plan it for when the owner is away.

Disk: about 45 GB in place, of which `out/` is 13 GB; 227 GB is free today. Before step 1, keep a copy of today's
`Chromium Framework.framework` (`apps/browser/build-solaracore/staged/5f55fa9f547c0b2a/Chromium Framework.framework`) outside `~/chromium-build`
so you can roll back.

The Hill Studio's `~/solara-engine/<hash>` frameworks are a second rollback.

Only the procedure's own resets and deletions touch `~/chromium-build/chromium_git/chromium/src/out`:
- deleting `out/` (step 3 of the procedure);
- `gclient sync --reset --force -D`;
- the `git reset --hard` and `git clean -ffd` the procedure asks for, run in `~/chromium-build/chromium_git/chromium/src` only, never in the Solara
  checkout (where `guard-git` blocks them).

The owner's approval covers this run only. Hold the chromium lock for the whole cycle, and never run `gn clean`.

## Safe Storage

`chromium-safe-storage-name.patch` (`components/os_crypt/common/keychain_password_mac.mm`) and
`chromium-safe-storage-no-silent-reset.patch` (`crypto/apple/keychain_v2.{h,mm}`, `fake_keychain_v2.h`) must not change.
None of their files changed in Chromium .47 → .79 or in Helium 0.20.1 → 0.20.3. Helium's `change-keychain-name`
(skipped) and `prevent-reset-on-keychain-unavailability` (a reviewed guard hit) are unchanged too.

The risks come from the process, not from upstream:
- A bulk context refresh could regenerate these two patches with new line numbers. Leave them out of any refresh, and
  require `git diff --exit-code engine/patches/chromium-safe-storage-*.patch` before the landing commit.
- If one of them ever stops applying, stop and ask the owner. Don't rework it.
- The `guard` stage must still pass with exactly the reviewed hits. A new hit on the keychain item name or on Safe
  Storage resets blocks the update.
- After the build, check that the framework still names the "Solara Safe Storage" item (`strings`) and that
  `helium-check-build.py` passes.
- A Debug instance runs on Chrome's mock keychain, so it never exercises Safe Storage. The release smoke's
  saved-password check on a team-signed build is the real test. Never use the owner's own profile or keychain for it.

## Order of work

1. Owner window agreed; take the chromium lock; download the Metal Toolchain; copy the current framework aside.
2. Update `env.sh` and `helium-pins.ini` to the pins above; check out Helium 0.20.3 and 0.20.3.1.
3. Set aside `domsubcache.tar.gz` and `.helium-stages-src`; reset the checkout; delete `out/` and the git dep checkouts;
   run `01-sync.sh`.
4. Run step 3 (`03-helium.py`), then step 4. Rework `chromium-helium-bangs-off` and `chromium-extension-omaha-attributes`,
   refresh the rest, and capture new files' bases; repeat until `series.py check` passes and the Safe Storage patches
   are unchanged.
5. Run step 2, then step 5 (in the background, under a guarded deadline per chunk); then `helium-check-build.py`.
6. `build-app`, the SolaraCore acceptance run, the release smoke; update `engine-build.md` (a "0.20.1 → 0.20.3" section
   like the existing one) and the engine identity line; land with a new `SolaraCore-<tree>-source.tar.xz` for the GPL
   source link.

# Engine update plan: Chromium 158.0.8127.88 on Helium 0.22.4 (original 0.4.8 migration)

Historical record. The owner deferred 158 to 0.4.9 on 2026-11-26. Reuse the existing 158 tree and output in the re-land. The preserved 157 no-silent-reset patch needs an owner decision before strict replay on 158.

Prepared on 2026-11-24. The owner approved sync and a full rebuild on the Hill Studio.
Procedure: [engine-build.md](../engine-build.md#rebuilding). Base commit: `67fa04750598597c068166ef4f8c8a9a2b1a23ac`.

**Resumed with owner approval on 2026-11-24:** rollback/reset and steps 1 and 3 passed.
All 381 Helium patches applied without fuzz; the existing four guard allowances passed.
The reviewed 158 revision replaced `chromium-safe-storage-no-silent-reset.patch` byte-for-byte
from eng158d's draft. `chromium-safe-storage-name.patch` remains unchanged.
**Stopped at the next meaning-change gate:** step 4 reached `chromium-document-pip-bar.patch`.
Strict series reproduction, GN generation and the detached build have not run.

## Target

| Pin | Today | Target |
|---|---|---|
| `CHROMIUM_VERSION` | 157.0.8103.50 | 158.0.8127.88 |
| `CHROMIUM_COMMIT` | `049750111b1e5c11565c792b2aeed5541f332bad` | `0cefb18236a23db1ebb6b2bc040fbbaf8cbe759e` |
| `HELIUM_TAG` | 0.21.2 (`e817502a99428528264c31268a8554e5ba63bd2c`) | 0.22.4 (`41a32da3ed31e0c4a550b7f317f5ab095deee1c9`) |
| `HELIUM_MACOS_TAG` | 0.21.2.1 (`913533798687460c163d704d5024efe8b3058b14`) | 0.22.4.1 (`0b5bf1274dfce6aa8163060d9a7172fd7bac409b`) |
| `SISO_VERSION` | `git_revision:dfc32e4edca158cff2b64a1658ee3940f0116b3a` | unchanged; 158's DEPS names exactly this revision |

The remote tag lists identify 0.22.4 as the newest helium-chromium tag for 158.
Its `chromium_version.txt` reads `158.0.8127.88`; macOS 0.22.4.1's `helium-chromium`
submodule points exactly to `41a32da3ed31e0c4a550b7f317f5ab095deee1c9`.
Chromium's Gitiles tag endpoint resolves to the target commit above.

## What changed upstream

Helium's series adds two WASM interpreter fixes; a sync provider host replaces its repository patch.
Other additions cover translation providers, page translation and UI, web push, density preferences,
pinned tabs and sync, cache encryption, history sync promo removal, a Reading Mode chip override,
and copying download links. `deps.ini` changed; `flags.gn` did not.
The macOS series adds native frame materials and replaces its old Sparkle integration layout.

### Skip list and guards: approved

These current `SKIP` entries are absent from the target macOS series and their patch files were deleted:

- `rebel/macos/sparkle-integration.patch`
- `helium/macos/updater/fixup-sparkle-glue.patch`
- `helium/macos/updater/disable-default-updater.patch`

The new `helium/macos/updater/sparkle-glue.patch` and existing `sparkle2-integration.patch`
are skipped together; `chromium-signing.patch` stays skipped. The three deleted entries above
were removed from `SKIP`. Password-manager disabling and keychain renaming stay skipped.
The acceptance rule is no-fuzz application of both series minus skips, with no dependency on
files or symbols supplied only by a skipped patch. Shared files with separate hunks are allowed.
The existing guards remain unchanged.

`change-keychain-name.patch` is unchanged. Upstream
`helium/macos/prevent-reset-on-keychain-unavailability.patch` remains applied under `GUARD_ALLOWED`.
Its 158 revision extends retry and fail-closed handling to configurable key tag/salt constructors
and the custom-data-directory `v11` / `pepper` provider. The owner approved replacing
`chromium-safe-storage-no-silent-reset.patch` with eng158d's independently reviewed 158 revision
on 2026-11-24. It preserves the creation gate, atomic add-only operation, duplicate readback and
fail-closed recovery while adapting constructors and tests to configurable tag/salt values and
locking the fake keychain's newly guarded fields. The name patch and `ac_safe_storage.mm` stay unchanged.
Any other patch requiring a meaning change stops this migration.

## Our series on 158

Eight patches were refreshed while preserving their existing purpose:

| Patch | Refresh |
|---|---|
| `chromium-helium-branding.patch` | Retain the inserted cache-encryption flag block; use the new origin override binding as context |
| `chromium-notification-platform-bridge-hook.patch` | Retain Chromium's new Mojo callback helper include |
| `chromium-devtools-control-token.patch` | Retain the new upstream peer-address constructor argument, initializer, member and call arguments alongside our token factory |
| `chromium-component-updater-security-only.patch` | Remove Helium's revised component gate, retaining Solara's existing security policy |
| `chromium-extension-window-hidden.patch` | Refresh dispatch contexts around Chromium's prebuilt navigation event argument lists |
| `chromium-helium-ublock-off.patch` | Refresh the three resource-header removal contexts |
| `chromium-helium-onboarding-off.patch` | Include the new push-messaging dependency in the removed onboarding target |
| `chromium-helium-services-page-off.patch` | Match the new consent binding and the services element without its old prefs binding |

Step 4 originally stopped at the no-silent-reset patch because Chromium 158 changed the
key-provider constructors to carry configurable tag/salt values. The owner-approved revision
now applies. `chromium-window-hosted.patch` received a context refresh retaining the new
`deferInputContextActivation` synthesized property; its additions and behavior are unchanged.
`chromium-ungoogled-disable-default-extensions.patch` retains the new build-guarded NTP
allowlist entry as context while still removing only the in-app payments entry.

## Cost and disk

Initial inspection reported 48 GiB free. Immediately before the locked tree changes,
`df -h /` recorded 58 GiB free; after sync it recorded 56 GiB; at the Safe Storage stop it recorded 55 GiB.
All readings exceeded the thresholds. The documented checkout is about 45 GB including a 13 GB output tree;
keeping 157's output by rename requires space for a fresh output tree, changed dependencies and linking.
`out.157-aside`, `domsubcache.tar.gz.157-aside` and `.helium-stages-src.157-aside` now hold the rollback data.
Existing 156 asides and other unmentioned build-root data were preserved.

## Execution status

1. Completed: approved Sparkle skip replacement; all 381 applied target patches have no references
   to `sparkle_glue`, `IDC_HELIUM_APPROVE_UPDATE` or `SparkleGlue`.
2. Completed: acquire chromium lock, preserve the three 157 rollback files/directories, reset checkout repos.
3. Completed: step 1 sync/hooks and step 3 Helium, including pins, guards and no-fuzz patches.
4. Completed (eng158g): remaining SolaraCore hooks and offline game applied under the chromium lock.
   Chromium 158 removed saved action-default persistence entirely; the old manager, restore function,
   browser_action state-store entry and its property keys have no replacement in the action subsystem.
   The owner approved removing our obsolete restore notification. Registry watchers and initial
   action queries still expose manifest defaults. The new acceptance.mjs extension-action-defaults-relaunch
   fixture expects programmatic icons, badges and titles to reset, matching Chrome 158.
   The fixture described by eng158f was absent from this clone, so this explicit relaunch check was added.
5. Completed: strict series.py check, 76 steps and 320 touched paths. Ten patches received context-only
   refreshes with identical added/removed lines. Applied the existing auto-PiP incognito-setting patch
   that the permissive apply pass had incorrectly treated as already applied. Safe Storage is unchanged.
6. Completed: step 2 GN generation (36709 targets, 5035 files). Detached step 5 started with nohup
   at 2026-11-25T04:30:26Z (2026-11-24 20:30:26 PST), PID 8698, under a command-duration
   chromium lock. Log: ~/chromium-build/logs/build-158.log. Free disk at launch: 46.1 GiB.
   Build completion is not awaited; see eng158g/result.md.

Do not repeat step 3 or the rollback renames. Step 4 was completed directly from the partial tree,
without rerunning the wrapper that misidentifies the auto-PiP helper after SolaraCore modifies it.
Compilation and runtime checks remain pending; the lead runs the acceptance fixture after the build.

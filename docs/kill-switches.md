# Kill switches

A speed change people can feel ships behind a switch, so it can be turned off for a bench, a bisect or a Mac where it
misbehaves. `apps/browser/src/lib/killSwitches.ts` is the registry. The app never fetches a switch file: Solara has no
switches URL, and the remote check was removed with the port off React Native. A switch's value comes
from `SOLARA_SWITCHES`, else from `switches-cache.json` in the data dir (written only by tests and benches), else on.

## Rules

- **At most 8 switches live** (`MAX_SWITCHES`). `killSwitches.test.mjs` fails above 8, and for any switch past its
  `removeBy` date: delete the switch and its old path, or move the date and say why in the commit.
- Every switch is **on by default**, has an `owner` (an area) and an `about` line, and falls back to the behavior from
  before the change when off, with a unit test of both paths.
- A switch is **`live`** when it's read where it's used (each call, never held in state), so a change to the cache
  applies at once. Otherwise it's read once at launch and a change applies at the next one.
- Reads are synchronous (`switchOn(name)`) and never re-render anything.

## For a bench or a test instance

`SOLARA_SWITCHES="newTabPrewarm=off,focusedWindowFirst=off"` sets a launch's values over everything else (the app and
the updater both read it).

## The switches (see `SWITCHES` for owners and dates)

| Switch | Off means | Live |
|---|---|---|
| `newTabPrewarm` | a New Tab page's tab is made by Enter, as before the prewarm | yes |
| `updatePrewarm` | a staged update waits for the quit without the hidden first run (read natively: `KillSwitch` in `Updater.swift`) | yes |
| `launchTab` | session.json keeps no launch hint and a launch claims nothing: the restored page loads once its window's content mounts, and the early window stays off (it also has its own environment switch, `SOLARA_EARLY_WINDOW=off`) | no |
| `focusedWindowFirst` | a launch opens every window at once, the focused one last | no |
| `sidebarSlide` | hiding or showing the sidebar jumps instead of sliding (it stays mounted either way); with the address bar in the sidebar, a hidden sidebar's bar moves to a toolbar on the card and the peek is Dia's | yes |
| `sidebarSlideLean` | every step of the slide lays the traffic lights out (AppKit then rewalks the window's views); read natively, once a launch: `ChromeWindows.swift` | no |

## Environment-only switches (launch and new tab, 2026-10-19)

Read once at launch from the environment, for a bench or a bisect; each falls back to the behavior before it.

| Variable | Off means |
|---|---|
| `SOLARA_EARLY_WINDOW_FIRST=off` | the launch tab starts before the early window is made, as before (`SolaraCoreHost.mm`) |
| `SOLARA_LAUNCH_SPARE_RENDERER=off` | no spare renderer is started for the launch tab; its navigation launches one |
| `SOLARA_SCRIPT_LOADER_AT_ONCE=off` | a content-script loader made after extensions are ready waits one task to start (engine) |
| `SOLARA_SCRIPTS_WAIT_AT_RESPONSE=off` | a navigation waits for content scripts before its request, not before its commit (engine) |
| `SOLARA_SCROLL_FULL_RATE=off` | as in 0.2.38: main frames drop to 60 Hz during a scroll and right after input on a 120 Hz display (the engine's `solara_full_rate_after_input` is 0 s), and on battery Battery Saver's 30 Hz cap holds through scrolling and typing (no input monitor); `SOLARA_MAIN_FRAME_THROTTLE=off` turns the whole 60 Hz throttle off |
| `SOLARA_WALLET_PASSES=on` | Chrome's `AutofillAiWalletPrivatePasses` stays on, and every new tab asks LocalAuthentication about Touch ID |
| `SOLARA_SYSTEM_FONTS=on` | expo-constants lists every font family at launch (`patches/expo-constants@18.0.14.patch`) |
| `SOLARA_EARLY_NAVIGATE=off` | a navigation is sent to the engine by its view's effect after React re-renders, not by the store action (`lib/earlyNavigate.ts`) |

## Developer flags (off by default, debug builds only)

Read through `launchEnvironment`, so a release build never sees them. A prototype lives here until the owner decides.

| Variable | On means |
|---|---|
| `SOLARA_WEBKIT_SIGN_IN=on` | moving a Chromium page to WebKit first copies the cookies that page's own address gets (HttpOnly included, partitioned ones left out) into the profile's WebKit store, so a cookie sign-in (Netflix, Spotify…) comes along; at most 1.5 s, then the move goes ahead either way (`lib/engineSignIn.ts`, `WebKitCookieImport.swift`) |

## Staged rollout

A release can also reach people in steps: `scripts/release.sh <version> --phased <seconds>` and the release skill's step 5b.

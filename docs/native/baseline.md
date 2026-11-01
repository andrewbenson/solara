# Native move: the measurement baseline

This is phase 0 of [architecture.md](architecture.md). It is a plan only: nothing here has been run.

What it fixes: the numbers every later phase is held to, measured on the **last React Native stable release**. Each
metric is defined by native endpoints (AppKit event time, Core Animation commit, the page's frame), so the same
probe reads an RN surface and its native replacement the same way.

## Conditions

- Run on the shipped stable build (`dist/<v>/export/Solara.app`; `Solara.app` in dists from before the rename), never a local Release or a nightly
  (`docs/perf/README.md` › "Gating a release" explains why).
- Wait until the overnight Chromium build and every other agent's build or bench are done. Hold the perflab lock for
  every timing phase, and keep the display awake (`caffeinate -d`). Record the load average with each run
  (native-bench already does).
- Use hidden instances (`SOLARA_BACKGROUND=1`, a scratch `SOLARA_DATA_DIR`, own port). The drag phase is the one
  exception (below).
- Profiles: the one-tab session, and the seed (`apps/browser/scripts/perf/seed.mjs`: 200 tabs in two profiles, 5,000
  history entries, 1,000 bookmarks).
- Report medians with p75, p95, min–max and n, as `sprint-baseline.md` does. A later phase regresses a row only when
  the ranges separate or the regression reproduces in a second interleaved round.

## Metrics

| # | Metric | Start → end | Scenario | Tool today | Gap to close |
|---|---|---|---|---|---|
| M1 | Tab switch, click → response | Row click (its mouse-up, which fires it; the mouse-down is kept as `press`) → CA commit with the row selected (`ui`); → the new page's second rAF after it turns visible (`page`) | `tab-actions.mjs` session (60 tabs, 2 profiles, pins, groups, 2 windows): `click`, `ctrlTab`, `cmdNumber`; `--n 5` per launch, 4+ launches | `tab-actions.mjs` + `actabs.m`, which also splits out "main wait": the flush waiting for the main thread, the direct cost of sharing it with Chrome | None. Add an `os_signpost` at "selection shown" (M9) |
| M2 | New tab | ⌘T key event → command bar committed, on screen and typeable; → New Tab page painted | 10 per run | `native-bench --only newtabkey` (J2), `tab-actions` `cmdT` | None |
| M3 | Omnibox keystroke → suggestions | Key event → suggestion rows in a CA commit; plus compute time alone per key | Type `github.com/net` and `react native perf` on the seed | J2 `keyAt` → `suggested` (`lib/perfMarks.ts`), `suggest-hermes.mjs` per key | Signpost "suggestions shown", so the native omnibox reports the same endpoint |
| M4 | Sidebar hover | Pointer enters a row → hover background in a CA commit; frames delivered / expected during a 24-row sweep at 120 Hz | Frame rig `hover`, driven from display-link ticks | `native-bench --only frames,framecounts` (`acframes.m`) | None |
| M5 | Window drag frame pacing | Drag start: `mouseDown` → first window move (ms, and pt of pointer travel). During the drag: window origin vs pointer per display frame (trail, pt), frames delivered / expected. End: error after mouse-up (pt) | 80×40 pt drags and fast wiggles (120 steps, 4 ms and 8 ms apart) from the toolbar, sidebar top, top strip, Settings title | None committed (746664cf used an uncommitted `drag.swift`) | `acperf postdrag` (below); visible window required |
| M6 | Main-thread stall histogram | Each main run-loop iteration's busy time, bucketed 8–16 / 16–33 / 33–50 / 50–100 / 100–250 / ≥250 ms; the same for the JS thread; for each iteration ≥ 50 ms, a stack sample attributed to Chrome, RN / Hermes or app code | Idle 60 s, then the ratchet's scenarios in order (typing, switchTabs, scroll, hover, pageLoad, openClose) | `acframes.m` measures busy time (totals); `acsample.c` samples the main thread (launch only) | Histogram output in `acframes.m`; `acsample.c` armed during scenarios; attribution by image (`Chromium Framework`, `hermes`, `React*`, app) |
| M7 | Launch → first window | `open -g -n` → window shown → JS running → window with content → page's first frame → FCP | Warm and cold (`--fresh-copy`), one tab and seed, 6+ launches each | `native-bench --only launch` (+ `launch-trace.mjs`, `launch-samples.mjs`) | A "core ready" signpost to stand in for "JS running" once the store is Swift |
| M8 | Memory per window | Δ `phys_footprint` of the browser process, and Δ total including helpers, per extra window holding one New Tab, k = 1..4, settled 10 s | Seed profile | `native-bench` memory and newwindow phases (`acperf rusage`) | A slope variant: k windows, a linear fit, report MB per window |
| M9 | Counts that survive RN | Per action: store commits, CA commits, AppKit layout passes, view updates | Same scenarios as M6 | The JS ratchet (React counts) | `SolaraSignposts` counters; the native ratchet later replaces the JS one |

Also keep the existing idle rows (CPU, wakeups at 1 and 20 tabs) from `native-bench --only session`. They catch a
native surface that polls.

## New probes

| Probe | Where | What it adds |
|---|---|---|
| `AC_BENCH_STALLS=1` in `acframes.m` | `apps/browser/scripts/perf/acframes.m` | A `CFRunLoopObserver` (before-waiting / after-waiting) on main and on the JS thread's run loop. It records each iteration's busy time into the buckets and writes `bench-stalls.json` per scenario window. |
| `acsample.c` scenario mode | `apps/browser/scripts/perf/acsample.c` | It arms on the bench's scenario markers instead of only at launch, and keeps the samples that fall in iterations of 50 ms or more. `launch-samples.mjs` already symbolizes them; a new `stall-samples.mjs` groups them by image. |
| `acperf postdrag <pid> <window id> <from x,y> <dx,dy> <steps> <gap ms>` | `apps/browser/scripts/perf/acperf.swift` | Real HID mouse-down, drags and mouse-up at the HID tap. It reads the window's frame from `CGWindowListCopyWindowInfo` after each step and writes per-step pointer and window positions. This matches the method in 746664cf. |
| `SolaraSignposts` | `os_signpost` log `network.benson.solara.perf`, emitted from RN-era code now (`perfProbe` sites) and from native code later | The fixed endpoints "selection shown", "suggestions shown", "core ready" and "New Tab painted". `acmark.m` reads them, so a metric keeps the same endpoint before and after its surface moves. |

## The script

`apps/browser/scripts/perf/native-baseline.mjs`, with flags in its `--help` header like the other benches:

1. `--app <stable app> --out <dir> --port <p>`. Prepare the signed copies once (`native-bench --only prepare`), and
   check `acperf display`.
2. Take the perflab lock. Run, interleaving the one-tab and seed sessions where a phase supports it:
   - `native-bench --only launch --launch-runs 8` (M7), then `--fresh-copy --launch-runs 4` (M7 cold);
   - `native-bench --only newtabkey,navigate --journey-n 10 --runs 3` (M2, M3, J4);
   - `tab-actions.mjs run --side stable=<its bundle> --launches 4 --n 5 --actions click,ctrlTab,cmdNumber,cmdT,cmdW,hoverClose,pin,unpin` (M1, M2, plus the close and pin rows);
   - `native-bench --only frames,framecounts --runs 3` with `AC_BENCH_STALLS=1` and `acsample.c` in scenario
     mode (M4, M6, M9);
   - `native-bench --only memory,newwindow` with the window-count variant (M8).
3. Release the lock and run `suggest-hermes.mjs` (M3 compute) under its own lock.
4. M5 only with `--drag` and a visible window (§7, item 9 in [architecture.md](architecture.md)). Otherwise its rows
   print "needs owner run".
5. Write `<out>/baseline.json` and render `docs/native/baseline-<version>.md`: one table per metric, with the machine
   state (load averages, display rate, idle-input seconds) at the top.
6. Clean up: quit every instance, `scripts/agent/unregister-builds`, remove `<out>` except the report.

Expected cost: about 90 minutes of machine time, plus 10 minutes for M5 with the owner's go-ahead.

## Re-running per phase

Every phase reruns this script with `--control <previous stable>`, interleaved. It adds phase-specific rows:
- phase 1: store dispatch p50/p99 on the seed, bridge patch bytes per action;
- phase 2: Settings open → content, pane switch, typing in search;
- phase 4: per-key compute in `SolaraOmnibox` against the Hermes numbers.

## Phase 2 results: Settings

Measured 2026-10-26 with `packages/settings/scripts/settings-bench.mjs --variants native,rn` on a local Release build
(both windows in the same build, `SOLARA_NATIVE_SETTINGS=0` for RN), interleaved under the perflab lock, 6 launches per
variant, 6 panes visited twice each. Medians in ms.

| | Native | RN |
|---|---|---|
| Open → General committed | 67 | 129 |
| Pane switch, median (max) | 45 (71) | 49 (79) |
| Footprint with Settings open | 139 MB | 138 MB |

| Pane, first / second visit | Native | RN |
|---|---|---|
| Tabs | 55 / 48 | 71 / 69 |
| Appearance | 46 / 44 | 48 / 44 |
| Privacy | 42 / 43 | 44 / 43 |
| Search | 51 / 46 | 50 / 51 |
| Advanced | 45 / 42 | 58 / 58 |
| Engines | 41 / 36 | 41 / 44 |

Before f8c59763 the panes were grouped `Form`s, which build every row on each visit: the pane switch was 78 ms against
RN's 48. The lazy form (`SettingsLazyForm.swift`) builds only the rows on screen; a pending search reveal builds the
whole pane for that visit. Open includes the pre-built window (`SettingsPrewarm`, about 13 MB held at rest); without
it native opens in about 320 ms. Typing in search isn't measured (it needs real key events in a key window).

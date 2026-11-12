# Roadmap

What ships in the next few versions. The owner decides what moves onto it; everything unscheduled stays in
[backlog.md](backlog.md). Statuses: planned → in progress → landed (hash) → shipped (version). An item that moves to
another version leaves this one; a dropped item goes back to the backlog.

At each release, mark that version's items shipped, move anything unfinished to the next version or back to the
backlog, and check this file against the release notes.

## 0.1.4: updates you can see, shortcuts that win

| Item | Status |
|---|---|
| "New Solara Version Available" pill in the sidebar (toolbar with horizontal tabs) and "Restart to Update Solara" in the app menu, on a background download | shipped (0.1.4) |
| The active pinned tab is obvious: flat inactive tiles, the active one raised and tinted with its icon's colour | shipped (0.1.4) |
| Tab, profile and window shortcuts win over pages (Google Sheets); per-shortcut Prefer Solara / Prefer Website / Use Both in Settings › Shortcuts | shipped (0.1.4) |
| Security fixes in shipped code (CodeQL #101, #104, #160, #162–167) | shipped (0.1.4) |
| Security fixes in test tooling (31 alerts) and dependency overrides | shipped (0.1.4) |
| Alert re-scan, fixes and the approved dismissals (CodeQL: 59 fixed, the rest dismissed with reasons; #102 and #103 left open) | shipped (0.1.4) |
| Perf ratchet runs again ("dev harness never answered" on 0.1.2 and 0.1.3) | shipped (0.1.4) |

## 0.1.5: sign-in windows that work, and profiles you can remove

| Item | Status |
|---|---|
| Sign-in windows ("Sign in with Google" on claude.ai, Slack's connect flow) open blank and take no input; 0.1.3's Space fix (bd3b6619) didn't cover it | shipped (0.1.5) |
| Remove from Sync…: a profile deleted on every Mac can be removed from sync, so no Mac offers it as "Add to This Mac" again | shipped (0.1.5) |
| Update safety: never move or delete staged updates ourselves; drop a staged nightly only through Sparkle's Skip; quit holds 8 s at most. Checked 2026-11-02: nothing deletes or moves in Sparkle's folder and there's no startup sweep; what's left is identity by path in UpdatePrewarm, which finds staged copies by walking Sparkle's Installation folder (it launches one only after a designated-requirement check, suspended, and verifies the started process's code before resuming it). Identity: staged copies are found by descriptor and inode, not path, and the launch is bound to the checked slice's cdhash; a Developer ID prewarm run is on the 0.1.5 release smoke | shipped (0.1.5) |
| Little Solara can keep new-tab links inside itself (a setting) | shipped (0.1.5) |
| Tabs moved to another window land where a new tab would open | shipped (0.1.5) |
| New Window opens on the profile you're in | shipped (0.1.5) |
| Closing the last tab keeps the window while it has pinned tiles or a pinned group | shipped (0.1.5) |
| A muted tab's or site's notifications make no sound | shipped (0.1.5) |
| The hidden sidebar doesn't peek out while another app is in front (in Swift) | shipped (0.1.5) |

## 0.2.0: the sidebar your way

| Item | Status |
|---|---|
| Icons-only sidebar rail, 84 pt: drag-to-snap, View menu and Settings toggle, hover × to close, loading and audio badges, the address bar moves to the toolbar | shipped (0.2.0) |
| Folder and group popovers, footer profile switcher, the hidden sidebar's peek in rail mode | shipped (0.2.0) |
| Share… in the page's right-click menu and File › Share (⌥⌘S): selected text, an image, a link with trackers removed, media, the page (engine change) | shipped (0.2.0) |
| A full emoji picker for profile, tab and folder icons (search, categories, symbols), and names that save on click-away; built in Swift, replacing the React Native icon pickers | shipped (0.2.0) |
| On a WebKit page, the pinned extensions give way to a WebKit pill (extensions, the ad blocker and password autofill don't run there), with Open in Chromium; the icons come back on Chromium tabs. The pill and its popover in Swift | shipped (0.2.0) |
| Going back to the New Tab page (⌘[ or a two-finger swipe) shows the New Tab page, not the command bar floating over the page you left | shipped (0.2.0) |
| Arrowing through command bar suggestions fills the input with the highlighted address or search, editable before Enter; Escape or arrowing back up restores what you typed | shipped (0.2.0) |
| Pinned extensions stay pinned (across quit and updates), and checking one in Pin Extensions pins only that one | shipped (0.2.0) |

## 0.2.1: fixes and a tidier icons-only sidebar

| Item | Status |
|---|---|
| The toolbar takes a page's header colour right when it's made with color-mix(), color() or oklch() (a light page showed a near-black toolbar, in light and dark) | shipped (0.2.1) |
| The Share picker opens at the click point when DevTools is docked on the left | shipped (0.2.1) |
| A tab no longer crashes when a page stops listening for permission changes after the frame it asked from is gone (engine patch; upstream Chromium, .79 included, still crashes) | shipped (0.2.1) |
| Sidebar width and icons-only are per window: resizing one window's sidebar no longer resizes every window | shipped (0.2.1) |
| Icons-only sidebar: narrower rail with square tiles, a hover × badge, the traffic lights in the toolbar as Chrome does, no tile fill at rest, pinned tabs styled like other tabs | shipped (0.2.1) |
| Switching light/dark updates background tabs' toolbar colour, so switching to one shows no old-colour flash | shipped (0.2.1) |
| Picture in Picture stays on top of full-screen windows, including other apps' full-screen spaces (owner, 2026-11-03) | shipped (0.2.1); the owner's hand test of Solara itself in full screen and on two monitors is still to do |

## 0.2.2: a fresh engine

| Item | Status |
|---|---|
| Engine: Chromium 156.0.8078.79 or newer (Chrome stable security updates; we ship .47), built on the Hill Studio's own Chromium checkout. Owner: build there and ship in 0.2.2 (2026-11-03) | shipped (0.2.2): 156.0.8078.79 with Helium 0.20.3, prebuilt engine 464d76967fba (12b9dc82) |

## 0.2.3: fixes

| Item | Status |
|---|---|
| Ad blocking is in force before restored tabs load at launch: each profile's first load waits for uBlock Origin (about 0.3 s), with a 3 s deadline (owner, 2026-11-04) | shipped (0.2.3) |
| Picture in Picture floats over other apps' full-screen Spaces in every mode: the engine sets the full-screen and activation flags itself, video and document PiP alike, with Keep on Top on or off | shipped (0.2.3) |
| The toolbar has no background of its own where it sits on the window frame (icons-only sidebar, toolbar above the card): the frame's gradient shows through, as in Dia and Arc; the address field and buttons keep their fills (owner, 2026-11-10) | planned |
| Picture in Picture moves freely across displays, including onto a display above the main one | shipped (0.2.3) |
| Picture in Picture settles on a usable display after a drop into a menu-bar or Dock strip, across a gap between displays, or onto a display that was unplugged | shipped (0.2.3) |
| The PiP probe finds a styled PiP window with Keep on Top off (test tooling) | shipped (0.2.3) |
| App builds and releases take the published engine for the tree before a local out/ build, so a stale or unlanded engine is never embedded | shipped (0.2.3) |

## 0.2.4: fixes

| Item | Status |
|---|---|
| The highlight-to-Search bubble over selected text is off by default; Settings turns it back on, and anyone who chose it keeps it (owner, 2026-11-04) | shipped (0.2.4) |
| WebKit pages get Picture in Picture: WebKit's preference is on, its window's return button brings Solara and the tab forward, and coming back to the tab closes it, as in Chromium (owner, 2026-11-04) | shipped (0.2.4) |
| Back to Tab in a call's pop-out (document Picture in Picture, such as Google Meet's) brings Solara and the call's tab to the front and closes the pop-out | shipped (0.2.4) |
| Sleeping tabs settings: a global switch, a delay (15 or 30 minutes, 1, 2 or 4 hours) and sites kept awake, in Settings › Tabs and the site controls | shipped (0.2.4) |
| Dependabot image-size alerts (#6, #7) cleared: the metro family moves from 0.83.3 to 0.83.8 | shipped (0.2.4) |

## 0.2.5: fixes

| Item | Status |
|---|---|
| Fixed: Restore Arc Folders as Groups removes the restored Arc bookmarks from the bar again; it made the groups but left every Arc bookmark behind whenever the native store owned the workspace | shipped (0.2.5) |
| Fixed: on macOS 27.2 the address bar no longer shifts a long address 2 pt when you click into it; the overflow inset is measured instead of fixed | shipped (0.2.5) |
| Smaller: The selected tab's glow is always on at full; its setting is gone (owner, 2026-11-05). Settings › Appearance › Selected Tab is removed and every reader draws Full; the stored and synced `selectedTabGlow` key stays as a retired key nothing reads, so older Macs are unaffected | shipped (0.2.5) |
| Fixed: an extension's permission dialog no longer stays stuck over the page when the popup that asked closes; every click hit the dialog's invisible layer until it was dismissed | shipped (0.2.5) |
| New: the offline game is "Where's the raccoon?" at night: new crowd, decoys and four moonlit backgrounds, the moon keeping its silver in every profile colour, the lamb's best score carried over (owner, 2026-11-05). Ships with the 0.2.5 engine, whose offline page packs it | shipped (0.2.5) |
| Fixed: Esc cancels a tab drag in the top tab strip, as it does in the sidebar: the tab goes back where it was, and the rest of the gesture drops nothing | shipped (0.2.5) |

## 0.3.0: tabs that cost less, and the first native bars

| Item | Status |
|---|---|
| Native bookmarks bar, with the native bookmark coordinator (see backlog) (moved from 0.4.0, owner 2026-11-04) | shipped (0.3.0): landed (452220d3, f47efcae, 13a488a7, 8e4238ff): the bar is native, and the native coordinator owns bookmarks in every distribution build; the JS bookmark writer is gone, edits and sync replacements go through the durable coordinator and JS is a projection; legacy bookmarks migrate natively and Chrome confirms them before sync resumes; safe mode shows bookmarks with edits and sync paused; Chrome's URL spelling with the original sync spelling kept; all bookmark acceptance checks pass |
| A native frame for extension popups (moved from 0.4.0, owner 2026-11-04) | shipped (0.3.0): landed: native Swift frame replaces the React Native popup; anchoring, page-driven sizing, dismissal (page click, outside click, Esc, toggle, tab switch, navigation, app switch, window close) and focus return covered by acceptance extension-popup-native-frame; Little Solara has no popups yet (backlog); visual check against Dia on the owner list |
| Content blocker hold, per navigation: hold only session-restored and launch tabs (an engine mark set before the navigation starts, primary main frame, http(s)), not every navigation in the profile during the launch window | shelved: the owner keeps today's hold (2026-11-05), every page waits for uBlock in the launch window |
| Video call pop-out (Google Meet and others: the floating window a call opens, document picture-in-picture): make getting back to the call's tab easy and obvious; first find out what that window lets us change | shipped (0.3.0): landed: a 40 pt Dia-style bar with Back to Tab always shown at the top left, the call tab's favicon and page title in the middle (also a way back), close on hover (owner, 2026-11-04; engine `chromium-document-pip-bar.patch`); its look waits on the owner's visual check |
| Tab discarding (highest priority of the performance items): Chromium's memory saver unloads background tabs and wakes them on click, with site exceptions and protection for tabs playing audio, holding a form or in a call; reconcile with Solara's existing sleeping tabs | shipped (0.3.0): ON by default: `nativeTabSleep` in `LaunchSwitch.onByDefault`; `TabSleepRunner` decides while the workspace is native and its pages are pooled, and the JS sleep sweep is dormant while it runs. The engine eligibility and per-profile exceptions (838681e6), keep-alive feed and page stamps (def20e95), runner (9467e594) and native Sleeping tabs settings (0aa649ca) are in. The feed reads `protectionKnown` under a lock and starts if the runner turns on after bundle evaluation (9d963f35); status reads under a lock (aa022936). The switch-on 2-hour soak passed: 11 tabs asleep, audio kept awake, every wake worked. `native-tab-sleep`, `discard-outcomes`, `sleep-eligibility`, `keep-awake-sites` and `sleep-pinned-capture` pass on a launch with no override. The JS fallback runs whenever the runner doesn't (pool or shell off, safe mode, `SOLARA_NATIVE_TAB_SLEEP=0` in development); remove it with those paths. A tab holding typed text or a touched form stays awake through Chromium's own eligibility (`kFormInteractions`, `kUserEdits`, protected for every discard but an external one), which the runner's `sleepIfEligible` asks; the JS fallback checks for unsaved input itself. The keep-alive feed schedules a flush only when a tracked page's own inputs change, and retries pages still waiting on native facts (1 s, backing off to 30 s) |
| Heavy tab detection: SolaraKit decides from attributed CPU and memory measurements, badges the tab natively and offers the existing protected sleep action | shipped (0.3.0): engine side landed: API 38 reports one-shot memory and cumulative CPU through `ac_tabs_memory` and `ac_tabs_cpu`; the app side landed: `HeavyTabPolicy` (over 50% of one core in 4 consecutive 15 s intervals, or over 800 MiB in 2 samples; cleared after 2 low ones or at once on missing or changed data; a CPU gap over 45 s restarts the count and keeps the badge), CPU sampled every 15 s and memory every 60 s, only while Solara is the active app and at once when it becomes active again, for at most 40 live awake Chromium tabs, an orange gauge badge on the tab's icon in the sidebar, rail and top strip, and Put to Sleep on its hover card through `TabSleepRunner.sleepOnRequest`, which keeps every protection and Chromium's reasons. The engine does not classify heavy tabs or change sleep eligibility. No automatic sleep |
| Per-tab CPU and memory attribution: Chromium's resource attribution splits a shared process's cost between its tabs | shipped (0.3.0): engine calls landed: API 38 `ac_tabs_memory` and `ac_tabs_cpu`, trusted profile-free bridge and registered `tab-memory` / `tab-cpu` checks. Memory reports estimated private footprint; CPU reports cumulative samples for app-owned interval rates. Build and acceptance validation pending |
| Memory use per tab on hover cards (native) | shipped (0.3.0): done: the native sidebar tab card shows "Memory usage: 152 MB", or "High memory usage · 1.2 GB" above 800 MiB (Chrome's per-tab line, `SidebarTabMemory.highBytes`), from one `ac_tabs_memory` call per card show, cached per tab and page; none for sleeping tabs, "—" when no value comes back, nothing at all without the export. Settings › Tabs › Show memory usage on tab hover cards (on, synced) |
| The toolbar keeps up with a sidebar resize: during a live drag the page follows the new width at once but the native toolbar lags behind it, leaving a gap (owner report on 0.2.6-nightly.1, 2026-11-09) | shipped (0.3.0): landed (7b4ac09b): the native window shell lays out the toolbar's frame and painted surface in the same pass as the page, and places the auto-hide strip under it; React Native no longer drives that geometry |

## 0.3.1: Chromium 157, and every tab's memory

Owner, 2026-11-09: these follow 0.3.0 rather than joining it, so the bookmark handover ships on its own. Items marked
"(Ardia)" were seen in Ardia 0.2.43 to 0.2.46-nightly.1; Solara builds its own version, never a merge.

| Item | Status |
|---|---|
| `solara tabs`: every open tab with its memory, from the engine's per-tab attribution (the hover card's figure): a table sorted by memory with each tab's title, its address (host first, so tabs are easy to tell apart), profile and asleep state, and a total; `--json` for scripts and `await tab_memory()` in `solara exec`, each entry with its DevTools target id. Served by a token-checked `/solara/tabs` beside `/solara/active` in the engine's DevTools handler, so it rides the Chromium 157 rebuild; only while "Let the solara command control Solara" is on (owner, 2026-11-10) | shipped |
| With the icons-only sidebar the window toolbar sits on the window frame with no band or gradient of its own (owner, 2026-11-10) | shipped, but 0.3.1 applied it to every layout; fixed in 0.3.2 |
| A page gets focus back when shown again after a native New Tab closes (Chromium 157 refuses fullscreen to an unfocused page), and a rare quit crash in late profile cleanup | shipped |
| Hover-card memory readings are bounded: forgotten when a tab closes or changes document, capped at 128 keys (mem30 follow-up) | shipped |
| Chromium 157.0.8103.50 on Helium 0.21.2 (from 156.0.8078.79; Chrome stable for Mac is 157.0.8103.51 as of 2026-11-09): re-sync the patch series, keep both Safe Storage patches unchanged, publish the engine; Ardia's 157 series is a reference for the rebase (Ardia) | shipped: engine 574046ecf2af |

## 0.3.2: the toolbar comes back

A fix-only release for 0.3.1, out as soon as it's gated (owner, 2026-11-11); the releases planned as 0.3.2 and 0.3.3 move up one.

| Item | Status |
|---|---|
| The toolbar sits on the window frame only with the icons-only sidebar; with the full sidebar and every other layout it has its band, gradient and hairline as in 0.3.0 (0.3.1 dropped them everywhere; owner, 2026-11-11) | shipped |

## 0.3.3: lighter launches, Arc's windows

| Item | Status |
|---|---|
| No 1 px line down the page's right edge at some sidebar widths: the card's fill showed through one device pixel because the page was laid out at a fractional width that the engine floors to whole points (owner, 2026-11-11) | done: the page and card are laid out on whole points at every sidebar width; no exposed fill at 197.5, 233.25, 260.75 or 240 pt in single, split and icons-only snapshots |
| Fixes from the owner's two-Mac sync-join test of 0.1.3 | waiting on the test |
| GitHub security alerts cleared: Dependabot (image-size, minimatch, deepmerge) bumped, the omnibox quick-create regex no longer slows on crafted input, test-script CodeQL alerts fixed or dismissed | in progress: CodeQL #201 (quick-create regex) and #200 fixed in 1161a442 (shipped in 0.2.1); the build-time Dependabot alerts (no usable fix) and the test-only CodeQL alerts wait on the owner's dismissal |
| Bookmark request receipts expire (mem30 follow-up; owner chose option 1, 2026-11-10): a receipt expires 300 s after verified completion, the newest 32 per engine kept, and a retry of an expired ID gets "expired". Moved from 0.3.1: review rounds rcpt3 and rcpt4 found and fixed a synchronous checkpoint per acknowledgment, main-actor blocking on receipt reads, remap pruning during an active read and an O(n) acknowledgment scan; explain the intermittent profile-delete cleanup latency before landing | landed |
| Sites with fraud checks work: YNAB showed "Something went wrong" on every load and Apple's guest checkout ended on "Page Not Found" in Ardia; check both in Solara and fix what fails; no page can open the screen-sharing picker without a click (Ardia) | done: both load in Solara with Chromium 157 (Ardia's failures don't reproduce); YNAB's fraud collector no longer throws, since getDisplayMedia isn't constructible any more; acceptance checks the picker needs a click |
| The address bar never stalls on dotted, dashed text such as `my-post.another-post.x:` (Ardia froze for seconds per keystroke); check the native omnibox and add the case to its tests (Ardia) | done: no stall in Solara (worst 0.2 ms per prefix up to 512 characters); the cases are in core's and the native omnibox's tests |
| Thousands of bookmarks stay fast: a 2,500-bookmark import, a large bar set to Always, the » menu and a folder of a few thousand on the bookmarks page, against the native bookmark owner (Ardia) | planned |
| macOS 27: the green button's Move & Resize and Fill & Arrange menus don't crash, and a window dragged to another display stays where it's dropped (Ardia) | no crash or snap-back reproduced on macOS 27.2 with two displays (public frame calls and drags; window-placement-test); the green button's own menus and Fill & Arrange wait on an owner check |
| Picture in Picture floats over other apps' full-screen Spaces and stays on the display it's put on, tiling window managers included (Ardia) | app side landed: floats over full-screen Spaces, stays on its display, and tiling window managers move it as AppKit allows (no Accessibility guard, owner); the engine half rides the 0.3.3 engine build |
| Profiles load when opened: at launch only the profiles the windows show start, the rest and their extensions start on first switch; a setting turns it off (Ardia measured 1.5 GB → 390 MB at launch with eight profiles) (Ardia) | planned |
| Closing the last window keeps it, as in Arc: no "Close N tabs?", the Dock brings back the same window with its tabs, groups and selection, and so does reopening after quitting with no window (Ardia) | done: 21 hidden lifecycle checks pass under both restore settings (last-window-test); a real Dock click, Spaces and Sparkle's restart wait on an owner check |
| Unread counts on tabs, pinned tabs and Top Apps, from the page title, the Badging API or a favicon dot (Ardia) | landed (title and favicon dot); the Badging API rides the 0.3.3 engine build |
| Tab numbers while holding ⌘: after about a second of ⌘ alone, each tab ⌘1–⌘9 reaches shows its shortcut as a small keycap at the row's end (pinned tiles, icons-only mode and the top strip too); releasing ⌘, another key or a click hides them; remapped keys show as bound (owner, 2026-11-11) | done: native keycaps after 1.0 s of ⌘ alone, matched to the owner's reference (25 × 18 pt, 1 pt rim); numbers from the same rows ⌘1–⌘9 select; a switch in Settings › Keyboard Shortcuts |
| Links from pinned tabs and Top Apps to other sites open in a Peek, with Gmail, Slack and Outlook redirect wrappers unwrapped; Settings › Tabs picks New tab, Peek or Little Solara (Ardia) | planned |
| WebKit tabs block ads and trackers with uBlock Origin Lite's lists, following the same blocking switch, lists and trusted sites as Chromium tabs (Ardia) | planned |
| Full screen: the whole window slides down with the menu bar and nothing is covered (owner's target, backlog 2026-11-01); Ardia's version, macOS's own title bar sliding down with the window buttons, is a reference, not the target | planned |
| Battery benchmark: energy per scenario from macOS's own `powermetrics` (an idle session, typing and tab switching, video playback), recorded in the perf gate against the previous stable so every release and each step toward 1.0.0 shows real energy numbers (owner, 2026-11-10) | planned |
| Main-thread stall watchdog: Debug and perf-bench builds record every main-thread stall over 8 ms with its stack (kept local, never sent), and the perf ratchet counts stalls per scenario. Chromium's browser UI thread is AppKit's main thread in Solara, so every stall delays the browser too (owner, 2026-11-10) | done: Debug and bench builds record stalls over 8 ms with stacks under the data dir (a forced 122 ms stall caught with its stack; 0 over 65 s idle); Release has none of it (probe-scan); the ratchet's stall ceilings stay pending until six unlocked runs commission them |
| Durable writes off the main thread: the bookmark journal's fsync/F_FULLFSYNC checkpoints, SQLite's fullfsync commits and session saves go to serial background writers; the main thread only hands data over and never waits on the disk except at quit (owner, 2026-11-10) | planned |

## 0.3.4: colour and control

| Item | Status |
|---|---|
| A light custom colour gets dark sidebar and tab-strip text, as Arc draws it, with a setting to turn it off; a dark colour keeps the selected tab's title white (Ardia) | planned |
| A coloured group shows its colour at rest; neutral groups show their box on hover only, as in Dia (Ardia) | planned |
| Arrowing through the command bar shows the highlighted suggestion in the field, as Chrome and Dia do, and Esc brings back what was typed (Ardia) | planned |
| A same-site page swap and a tab switch keep the old page up until the new one draws: no white flash (Ardia) | planned |
| Set Solara up from files: settings, keybindings and themes in `~/.config/solara/config.json` and `themes/<name>.json`, applied at launch and on every save, never written back (Ardia) | planned |
| Hooks in `~/.config/solara/hooks.json`: rewrite or block links before they open, send links from an app to a profile, file finished downloads, deny camera or microphone, run a command on an event; anything reaching outside the page waits for approval in Settings (Ardia) | planned |
| Search and decoding off the main thread: omnibox suggestions on a background actor that drops queries typed past (2.8 ms a keystroke at 5,000 history entries today, growing with history); favicons and images decoded and resized off the main thread; session and store snapshots encoded there too (owner, 2026-11-10) | planned |
| One UI update per frame: several store changes in the same frame merge into one view update instead of a layout each; live gestures (resizing, dragging) still apply their geometry in the same event (owner, 2026-11-10) | planned |
| Fewer, coalesced timers: repeating timers on the main thread (the tab-sleep sweep, the pairing observer) get tolerance, merge, or give way to notifications instead of polling; good for battery too (owner, 2026-11-10) | planned |

## The road to all Swift (0.4.0 to 1.0.0)

React Native leaves one layer at a time: first it stops drawing, then it stops deciding, then it stops holding data,
then it's switched off, and only then is it deleted. Settings, onboarding, Import, New Tab, the omnibox, the internal
pages, the link bubble and the store are already native (RN removal 01–08). Each milestone ships as its own release;
feature releases can fit between them. New UI is built in Swift from now on, never in React Native.

Progress, updated at each release (from [native/rn-inventory.md](native/rn-inventory.md)): on 2026-11-03, 388 files and
54,494 lines of TypeScript are left in apps/browser/src: 12,097 draw, 24,435 decide, 13,639 hold data and 4,323 are
glue. React Native starts from 3 entry points (the main window, panes, and the version-mismatch screen), with one root
per window plus a root for each visible pane.

## 0.4.0: React Native draws nothing

Done when no React Native view appears on screen; React Native only arranges native views.

| Item | Status |
|---|---|
| Inventory every file left in apps/browser/src by what it does (draws, decides, holds data, glue) and the milestone that removes it: docs/native/rn-inventory.md | landed b1a78d3d |
| The New Tab page's remaining React Native parts: Personalize, the feedback check-in and the release postcard | planned |
| Native site controls and prompts (permissions, autofill, translate, zoom, developer mode) | planned |
| Native extensions toolbar, overlays and side panel | in progress: popup frame (ea03e788, ee1d3c67), side panel card and container, and native dialog sheet for install, permission and pin dialogs; extension menus, the toolbar model and Little Solara popups next |
| Native media: sidebar player, hover player, cast and share pickers, tab badges | in progress (tab badges, share bar) |
| Native peek, Little Solara, calendar and meeting cards | planned |
| Native top tab strip, split chrome, swipe overlay and the rest of the layout surfaces | planned |
| Sidebar on the right: a Left/Right position in Settings, the View menu and the sidebar's menu; peek, resize, hover cards and drops mirror; the window buttons stay top left (as in Arc and Zen); built with the layout port, so it's written once, in Swift | planned |
| Only build what's visible: sidebar rows exist only for what's on screen, and row views are reused instead of one view per tab (a 200-tab session spent ~480 ms of launch building rows) (owner, 2026-11-10) | planned |
| Launch in a smarter order: the window chrome first; invisible work (the extensions toolbar, sync, history hints, tab-sleep sweeps, pairing timers) when the main thread is idle, with lower priority classes for import, sync and cleanup (owner, 2026-11-10) | planned |

## 0.5.0: React Native decides nothing

Done when every user action is handled in Swift; JavaScript only mirrors state.

| Item | Status |
|---|---|
| Commands, menus and shortcuts in Swift | planned |
| Tab and window drag and drop, folder and group actions in Swift | planned |
| The omnibox's actions and the sidebar's actions in Swift | planned |

## 0.6.0: the data layer is native

Done when JavaScript holds no state of its own.

| Item | Status |
|---|---|
| The sync engine in Swift | planned |
| Legacy migrations in Swift | planned |
| The JavaScript mirror of the store is gone | planned |

## 0.7.0: React Native off by default

Done when a full release cycle passes with the React Native fallback never needed.

| Item | Status |
|---|---|
| The app starts without React Native; React Native stays bundled as a fallback, switched off | planned |

## 1.0.0: all Swift

React Native and Expo are gone: the app is Swift on SolaraCore, with no JS runtime, no Hermes, no Metro and no
Expo modules.

| Item | Status |
|---|---|
| Remove Expo, react-native-macos, Hermes and Metro; the Xcode project builds without Pods for JS | planned |
| Move the repo from pnpm to Bun where JS tooling remains | planned |
| Perf: the speed comparison against the previous stable, deferred since 0.1.0 | planned |
| Revamp the `solara` command (apps/cli, docs/cli.md): scope to be set with the owner; its connection to the app is built in Swift (settings and keybindings from files, a local control socket, event hooks), not on the JavaScript side (moved from 0.3.0, owner 2026-11-04: after the port) | planned |
| Revamp the Raycast extension (extras/raycast-solara) against the revamped CLI (moved from 0.3.0, owner 2026-11-04: after the port) | planned |
| Publish the extension on the Raycast Store: meet its review guidelines and submit to raycast/extensions (a public PR in another project, so it needs the owner's OK at submission) (moved from 0.3.0, owner 2026-11-04: after the port) | planned |

## 1.1.0: a VPN per profile, and Safari extensions in WebKit mode

| Item | Status |
|---|---|
| Attach a WireGuard configuration to a profile (import a .conf or paste one; the private key lives in the Keychain, never in sync) | planned |
| A WireGuard tunnel inside Solara, in userspace with no system VPN or admin prompt (wireguard-go or boringtun), one per configuration, exposing a local proxy only Solara can reach | planned |
| Route all of the profile's traffic through it: Chromium's per-profile proxy (pages, extensions, downloads, service workers) and WebKit's per-data-store proxy; Solara's own requests for that profile go through it too | planned |
| No leaks: DNS resolves through the tunnel, WebRTC is forced through the proxy, HTTP/3 falls back to TCP, and a tunnel that drops stops the profile's traffic rather than letting it out; leak tests for DNS, WebRTC and the visible IP | planned |
| A connected / connecting / failed indicator in the profile's sidebar | planned |
| Safari web extensions in WebKit mode, for password managers first (owner, 2026-11-11: 1Password is the motivation). Prototype first, 1 to 2 weeks: load a Safari web extension from an installed app's `.appex` with WebKit's `WKWebExtensionController` (macOS 15.4 and later) into WebKit-mode tabs, and find out whether native messaging reaches the extension's own handler so 1Password and Bitwarden can talk to their apps; that answer decides the rest | planned |
| If the prototype works: Solara's tabs and windows exposed through `WKWebExtensionTab` / `WKWebExtensionWindow`, native toolbar buttons, popups and permission prompts (SolaraKit, like the 0.3.0 popup frame), an extensions list per profile, and discovery of installed apps that carry Safari extensions. Limits: WebKit tabs only (Chromium tabs keep Chrome extensions), Safari's API subset, and apps that only expect Safari | planned |

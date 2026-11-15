# Roadmap

What ships in the next few versions. The owner decides what moves onto it; everything unscheduled stays in
[backlog.md](backlog.md). Statuses: planned → in progress → landed (hash). An item that moves to another version
leaves this one; a dropped item goes back to the backlog. Keep a status to what's left; the detail of how it was
verified belongs in the commit message.

When a version ships, check this file against its release notes, move anything unfinished to the next version or back
to the backlog, and move the version's section, unchanged, to the end of [shipped.md](shipped.md).

## The road to all Swift (0.4.0 to 1.0.0)

React Native leaves one layer at a time: first it stops drawing, then it stops deciding, then it stops holding data,
then it's switched off, and only then is it deleted. Settings, onboarding, Import, New Tab, the omnibox, the internal
pages, the link bubble and the store are already native (RN removal 01–08). The port runs through 0.4.x, one layer per release (owner 2026-11-14: 0.5.0 and 0.6.0 folded into
0.4.x); 0.4.6 is the first release that starts without React Native, 0.5.0 confirms it was never needed, and
1.0.0 deletes it. A feature release takes the
next 0.4.x number when it fits between them. New UI is built in Swift from now on, never in React Native.

Progress (from [native/rn-inventory.md](native/rn-inventory.md)): recounted on 2026-11-14 after the
Downloads, toolbar backdrop and no-shell group cutover, 401 files and 52,044 lines of TypeScript remain in apps/browser/src:
5,376 draw, 28,441 decide, 13,406 hold data and 4,821 are glue. Shared layout controls draw nothing;
their existing native surfaces host the consumers, while larger retained RN surfaces are listed in the inventory.
Source counts include retained fallback and unconsumed exports; they are not measured live pixel counts.
React Native still registers main and pane module names, with one main root per browser/Little Solara window
and a pane root per shown overlay; the API-skew screen reuses main.

## 0.4.0: React Native draws nothing

Done when no React Native view appears on screen; React Native only arranges native views.

| Item | Status |
|---|---|
| Inventory every file left in apps/browser/src by what it does (draws, decides, holds data, glue) and the milestone that removes it: docs/native/rn-inventory.md | landed b1a78d3d |
| The New Tab page's remaining React Native parts: Personalize, the feedback check-in and the release postcard | native drawing wired: Personalize, the due feedback banner and release postcard/page use Swift hosts; JS state, actions and feeds remain for later milestones |
| Native site controls and prompts (permissions, autofill, translate, zoom, developer mode) | in progress: existing native prompt/chooser/site/zoom bodies now serve every former shared-control consumer; RN fallback bodies, translation rows and developer button/URL-field bodies removed. Selection bar is native in Little Solara, Peek and no-shell windows. JS actions/feeds remain; ToolbarBackdrop developer stripes now draw in Swift; unit/typecheck/Debug, hidden consumer and refused-session drivers, AppKit input guards, and matched control captures pass; real VoiceOver/hover feel remains an owner check |
| Downloads popover skin/button/motion, toolbar backdrop and no-shell GroupPanel | native drawing wired: Swift hosts reuse DownloadsPanelView and SidebarGroupCardView; JS retains state, placement and actions. Debug build, targeted Swift tests and hidden downloads/toolbar/group drivers pass in both shell modes; live material/motion and VoiceOver speech remain owner checks |
| Native extensions toolbar, overlays and side panel | drawing complete: shared Swift popup frame now serves Little Solara, existing NSMenu context/overflow menus retain their actions, native extension buttons support keyboard/VoiceOver and RN button/badge drawing is deleted. Native side panel and install/permission/pin sheets remain. JS toolbar model, menu actions and lifecycle adapters stay for 0.4.4; real VoiceOver, menu tracking and Dia visual checks remain on the owner list |
| Native find bar | drawing complete: FindBarView is unconditional on existing main/split/Little Solara/legacy Peek mounts; JS find/replace/focus remains for 0.4.2. Studio Debug build, 11 native Find tests and 95 driver checks pass; 23 matched fixed crops are pixel-identical. Queued focus and native AX actions/state are verified; real VoiceOver speech remains an owner check |
| Native media: sidebar player, hover player, cast and share pickers, tab badges | in progress (tab badges, share bar) |
| Native peek, Little Solara, calendar and meeting cards | in progress: crash/unresponsive controls now host native SadTabView in Little Solara and other inline consumers; small-window card fill/page hosting remains |
| Native top tab strip, split chrome, swipe overlay and the rest of the layout surfaces | in progress: existing native swipe capsule/history list hosted in Little Solara and inline consumers; shared-pin snapshot/wash hosted by native FrozenPageView with guarded painted/activation callbacks; shared favicon images/initials and exhausted-retry recovery rows now host Swift views; layout-port Patches 1–3 add contracts, native work counters, projection, anchors and per-window sidebar/strip ownership; Patch 6 adds native pane/split placement and atomic page/overlay slots while preserving the global page pool; Patch 7 adds native toolbar auto-hide, command/find holds and renderer fullscreen pane covers with separate window Spaces policy, behind the same isolated-development capability; Patch 8 moves swipe gestures, history-list selection and history popover interaction to Swift behind the same isolated-development capability; Patch 9 adds store-derived native Peek, fenced motion/promotions, reveal holds and native tour anchors; RN pane roots remain content guests, with default cutover and the remaining surfaces still planned (`docs/native/layout-port.md`) |
| Sidebar on the right: a Left/Right position in Settings, the View menu and the sidebar's menu; peek, resize, hover cards and drops mirror; the window buttons stay top left (as in Arc and Zen); built with the layout port, so it's written once, in Swift | in progress: layout-port Patch 4 implements local position policy, native spatial mirroring and physical-left caption reservation behind `SOLARA_NATIVE_WINDOW_LAYOUT=1`; default shipping cutover remains Patch 11 |
| Only build what's visible: sidebar rows exist only for what's on screen, and row views are reused instead of one view per tab (a 200-tab session spent ~480 ms of launch building rows) (owner, 2026-11-10) | planned |
| Launch in a smarter order: the window chrome first; invisible work (the extensions toolbar, sync, history hints, tab-sleep sweeps, pairing timers) when the main thread is idle, with lower priority classes for import, sync and cleanup (owner, 2026-11-10) | in progress: Patch 10a adds native generation-scoped readiness, bounded idle admission and input/resize pauses. Visible React guests still hold readiness until Patches 6/7 remove their layout ownership; native selected-page draw instrumentation and service ports 10b–10d remain (`docs/native/layout-port.md`) |

## 0.4.1: polish on the new native layout

Small changes to surfaces 0.4.0 made native, while they are fresh: they need the native tab strip, rail and window
layout, and the profile dots fix replaces a React Native pager 0.4.0 retires.

| Item | Status |
|---|---|
| Fix: when Solara opens on a profile that isn't first (Work, second of four), the sidebar's profile dots light the first dot until you swipe; they should show the open profile's place from launch (owner 2026-11-14, seen on 0.3.5) | planned |
| Full screen: no window buttons at rest; when the pointer reaches the top, a small rounded island with the three buttons slides down about 10 pt below the menu bar, at the left, over the sidebar, on a Liquid Glass capsule (NSGlassEffectView), and nothing underneath moves; same on a Mac that always shows the menu bar in full screen; the system's own full-screen title bar reveal sets the timing; windowed unchanged; buttons stay top left with the sidebar on the right. Modelled on Rex (80 x 34 pt island, 9 pt from the left). Mock: https://claude.ai/artifact/EDrrFhwur4Jok5AVNDBPg3 (owner 2026-11-14) | planned |
| New tabs open at the top by default, and the + New Tab button sits there too (owner 2026-11-14); existing installs keep what they chose. The change touches the recorded settings fixtures (adapter and phase 1b replays) and the replay harness, which drops cases when its source tests fail: re-record on a current base without losing a case. The Dia onboarding preset still picks bottom; owner to decide | in progress: defaults and order-dependent tests done (deftop fin4), replay fixtures left; moved from 0.4.0 |
| Fix: a portrait Picture in Picture (a phone video, a person talking) can't be made as small as a landscape one; its smallest size is still very tall. The minimum should follow the video's shape, for dragging the edge, pinching and the remembered size (owner 2026-11-14, seen on 0.3.5) | planned |
| Fix: Picture in Picture dragged onto a display that shows another app's full-screen Space doesn't appear over it; it only shows there once that display leaves full screen (owner 2026-11-14, seen on 0.3.5). Dragging across displays and past the menu bar already works (2c61e084, 8881dfe1); the window keeps its Space membership from the display it left. Verify on two displays with a full-screen app on the target one (owner check: Spaces and multiple displays) | planned |
| One setting for where new tabs go: "New tabs: At the top / At the bottom / Below the current tab"; the + New Tab row sits where the new tab will appear (top, or docked at the bottom); only with Below the current tab does a "Button: Top / Bottom" choice appear. Replaces Add new tabs and New Tab button; saved choices carry over (owner 2026-11-14) | planned |
| Shortcut keycaps (hold ⌘): quiet keycaps instead of white stickers: 0.5 pt outline and 6% fill in the sidebar's text colour, 18 pt tall, one right-aligned column 8 pt in (the ✕ slot); a long title's fade ends 6 pt before its keycap while ⌘ is held (a text mask, so it works on any row or theme) and slides back on release; pinned tiles get the same keycap in the bottom-right corner, its right edge in the rows' keycap column (so the right-hand tile's lines up with the rows), icon unmoved; shown after ⌘ is held 0.25 s, 120 ms in, 80 ms out; ⌘9 on the last tab. Also fixes the clipped labels (⌘3 and ⌘5 cut on the right): size the keycap from the label's own cell measurement (NSTextField adds its own padding that the NSString measurement misses), centre the text over the whole keycap, use monospaced digits, never shrink the font to fit, and add a snapshot test that every ⌘1–⌘9 glyph run sits inside its keycap with at least 3 pt each side. Tabs on top: keycap in each tab's ✕ slot; narrow and pinned tabs get a corner digit with the favicon dimmed. Icons only: each icon nudges 5 pt left while ⌘ is held and its digit sits to its right, vertically centred, one straight column at the rail's right edge; the nudge and the digit's fade share one curve and start together (120 ms ease-out in, 80 ms back), check it frame by frame at 120 fps. While keycaps show, the ✕ under them is hidden and can't be clicked: a ⌘-click on a keycap acts like a ⌘-click anywhere else on the row (it selects the tab), never closes it (owner 2026-11-14: today ⌘-click on a keycap closes the tab through the ✕ beneath). Modelled on Rex. Mock: https://claude.ai/artifact/6oc6GQunbdThFEauCXVwTJ (owner 2026-11-14; tiles: option A, corner keycap) | approved by the owner 2026-11-14 (mock final) |

## 0.4.2: commands and the omnibox decide in Swift, and + New Tab is the new tab

The first half of "React Native decides nothing": every command a user gives through a menu, a shortcut or the
omnibox is handled in Swift. Done when menus, shortcuts and the omnibox work with their JavaScript handlers switched
off.

| Item | Status |
|---|---|
| Commands, menus and shortcuts in Swift, with window, focus and navigation handling | planned |
| The omnibox's actions in Swift: what Return opens, where it opens, clipboard and paste-and-go | planned |
| Settings and Import actions call Swift directly, not a JavaScript round trip | planned |
| + New Tab is the new tab: ⌘T, + New Tab, the strip's + and New tab opens: Command Bar select the + New Tab row itself and show the New Tab page, with no extra row; going somewhere (or typing in its address field) moves it into the list where new tabs go, with the open animation; ⌘T again while it's still empty settles the empty one into the list as a New Tab row and starts a fresh placeholder, so several ⌘T presses still give several New Tab pages; an untouched placeholder you switch away from is discarded (never saved, synced or offered by Reopen Closed Tab), while settled rows stay. With Below the current tab the placeholder shows under the current tab. Internally it's a real tab from the first ⌘T, so extensions see it as in Chrome (owner 2026-11-14) | planned |

## 0.4.3: agents, with limits you set

Tab actions from agents call the Swift commands 0.4.2 brings, so they are written once. The control path is already
native (the engine and the native store), so the rest does not wait on the port.

| Item | Status |
|---|---|
| `solara mcp`: an MCP server in the `solara` command for Claude Code, Codex and Cursor, over the existing control path (no new listener); read-only tools by default, acting tools behind `--allow-actions`, never `exec`; page text marked untrusted; `solara mcp install`; every tool carries MCP's standard annotations as Claude reads them (`title`, `readOnlyHint`, `destructiveHint`, `idempotentHint`, `openWorldHint`), set per tool, with the sidebar editor split so deleting a group is its own destructive tool (owner 2026-11-14, moved from 0.4.0) | built, parked for 0.4.1; annotations to refine |
| The `solara` command lists what's open: `solara profiles`, `solara windows`, and `solara tabs --window/--profile/--group/--asleep/--awake`; one tab ID across `tabs` and `sidebar` so commands chain (owner 2026-11-14) | drafting |
| Everyday tab actions from the command line: `solara open URL [--window] [--profile] [--background]`, `solara tab activate/close/reload/duplicate/mute/sleep`, close duplicates, sleep tabs idle for a while; never brings Solara forward unless asked (owner 2026-11-14) | planned |
| Search from the command line: `solara find` across open tabs, pins and recent history; `solara history` as a plain command (owner 2026-11-14) | planned |
| Profiles agents can't reach: a per-profile setting that keeps the `solara` command and MCP out of a profile, enforced by the app on the control connection, not by the command; new profiles allow agents by default; the command's history and pins reads move into the app so the setting covers them; listings hide blocked profiles' names and say only how many are closed to agents (owner 2026-11-14) | design settled; build next |
| One Agents pane in Settings (Swift) for both the MCP server and the `solara` command: the master switch, per-profile access, and per app read-only or "can act"; "Add" for each agent app found (Claude Desktop through its own extension install, Claude Code, Codex and ChatGPT desktop through their shared config, Cursor and VS Code through their install links, the rest by copy or a reviewed file edit); every edit shows its lines first, keeps a backup, leaves other servers alone and has Remove; says when an app needs a restart. The MCP entry runs the command inside Solara.app, so nothing else is installed. ChatGPT on the web isn't offered: it needs a public endpoint (owner 2026-11-14) | planned |
| The terminal command stays a separate, explicit choice: per coding agent "also let it use `solara` in the terminal (full control)", off by default, installing the command and its skill; plus the existing install for people. The app enforces scope: the MCP gets a read-only key unless actions are allowed, the command a full key, and the control connection refuses anything outside a key's scope or profiles (owner 2026-11-14) | planned |
| Revamp the `solara` command (apps/cli, docs/cli.md): scope to be set with the owner; its connection to the app is built in Swift (settings and keybindings from files, a local control socket, event hooks), not on the JavaScript side (moved from 0.3.0, owner 2026-11-04: after the port; moved up with the agents work, owner 2026-11-14) | planned |
| Revamp the Raycast extension (extras/raycast-solara) against the revamped CLI (moved from 0.3.0, owner 2026-11-04: after the port; moved up with the agents work, owner 2026-11-14) | planned |
| Publish the extension on the Raycast Store: meet its review guidelines and submit to raycast/extensions (a public PR in another project, so it needs the owner's OK at submission) (moved from 0.3.0, owner 2026-11-04: after the port; moved up with the agents work, owner 2026-11-14) | planned |

## 0.4.4: the sidebar and tab strip decide in Swift

The second half: done when every user action is handled in Swift and JavaScript only mirrors state.

| Item | Status |
|---|---|
| Tab and window drag and drop, folder and group actions in Swift | planned |
| The sidebar's and the top strip's actions in Swift: selection, close, rename, pin and move | planned |
| Media, extension, prompt and translation lifecycles in Swift; the TypeScript fallback reducers retire | planned |

## 0.4.5: the data layer is native

Done when JavaScript holds no state of its own.

| Item | Status |
|---|---|
| The sync engine in Swift | planned |
| Legacy migrations in Swift | planned |
| The JavaScript mirror of the store is gone | planned |

## 0.4.6: React Native off by default

The app starts without React Native; it stays bundled as a fallback, switched off.

| Item | Status |
|---|---|
| The app starts without React Native; React Native stays bundled as a fallback, switched off | planned |

## 0.5.0: all native, and windows that sync

Done when a full release cycle (0.4.6 to 0.5.0) passes with the React Native fallback never needed, and window sync
works between two Macs (owner 2026-11-14: window sync joins 0.5.0; the full-cycle bar stays).

| Item | Status |
|---|---|
| The React Native fallback was never needed through 0.4.6's cycle: no fallback launch in testing or on the owner's Macs | planned |
| Sync with several windows when tabs aren't shared between windows (`shareTabsAcrossWindows` off): today it isn't clear which window a profile publishes, and it feels like data is lost. Design agreed with the owner 2026-11-14: (1) a primary window per profile: one shared tab list both Macs edit (two writers), marked in the sidebar, with Window › Make This the Primary Window; closing it never deletes its tabs. (2) Every other window becomes a synced window object, offered on other Macs and never opened by itself, listed only for the profile the window shows, never other profiles' names ("From MacBook Air › Research, 12 tabs" while in Work); the user opens a single window, or all of the profile's windows at once, as tab groups in the primary window (default) or as windows; once open on both Macs both edit it. Opened as a group inside the primary window, it stays its own object placed there on this Mac only: the primary's shared list doesn't carry it, so other Macs' primary windows don't change; dragging a tab out of the group into the primary's own tabs moves it into the shared list. A deliberate "Move into Primary" folds the whole window into the shared primary as a group on every Mac and closes its separate window wherever it was open (owner chose this split 2026-11-14). Window names (no AI): the user's name wins; else a group holding most of the window's tabs; else a site with at least 40% of them (Tidy's site naming); else the two most common sites; an empty or New Tab-only window has no name and isn't offered; duplicates get a number; the automatic name follows the tabs until the user renames it or it's opened on another Mac, then it freezes; shown in the list, the window title and the linked group. The list (Swift): a favicon strip (first five or six, then +N), tab count and last used time per window; a hover card listing its tabs grouped as in the window, the active one marked, the first 15 or so then "and N more"; a disclosure arrow to expand the tabs inline and open a single tab; search over window names and tab titles and URLs; no page thumbnails. (3) Closing asks "this Mac only" (default) or "everywhere"; unopened objects stay listed 30 days. Merge: per-tab records, close beats a concurrent navigation (only Reopen brings a tab back), moves between lists are a container change, fractional order as pins; older versions must ignore the new records. New windows are offered by default, "Don't sync this window" for scratch windows; opened objects carry a link icon (owner 2026-11-14; Build order: primary window first (fixes most of the confusion), then window objects, then close-here/everywhere and the 30-day list. Ardia (upstream, checked 2026-11-14) has today's model and hasn't touched it; Arc syncs Today tabs across windows and machines (Arc 1.5 reverted a per-window attempt); Dia added unpinned-tab sync across devices in 2026. Today pins sync per profile from the frontmost window; open tabs only as "Your Devices" (`tabs:<device>`)) | design settled |

## 1.0.0: all Swift

React Native and Expo are gone: the app is Swift on SolaraCore, with no JS runtime, no Hermes, no Metro and no
Expo modules.

| Item | Status |
|---|---|
| Remove Expo, react-native-macos, Hermes and Metro; the Xcode project builds without Pods for JS | planned |
| Move the repo from pnpm to Bun where JS tooling remains | planned |
| Perf: the speed comparison against the previous stable, deferred since 0.1.0 | planned |

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

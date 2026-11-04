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
| Fixes from the owner's two-Mac sync-join test of 0.1.3 | waiting on the test |
| The toolbar takes a page's header colour right when it's made with color-mix(), color() or oklch() (a light page showed a near-black toolbar, in light and dark) | landed a1d6ccda |
| The Share picker opens at the click point when DevTools is docked on the left | landed 0fa6e53e |
| A tab no longer crashes when a page stops listening for permission changes after the frame it asked from is gone (engine patch; upstream Chromium, .79 included, still crashes) | landed 9bc625fa |
| Sidebar width and icons-only are per window: resizing one window's sidebar no longer resizes every window | landed 1c3e58ef |
| Icons-only sidebar: narrower rail with square tiles, a hover × badge, the traffic lights in the toolbar as Chrome does, no tile fill at rest, pinned tabs styled like other tabs | planned |
| Switching light/dark updates background tabs' toolbar colour, so switching to one shows no old-colour flash | landed 5cb63f15 |
| Picture in Picture stays on top of full-screen windows, including other apps' full-screen spaces (owner, 2026-11-03) | planned |

## 0.2.2: a fresh engine

| Item | Status |
|---|---|
| Engine: Chromium 156.0.8078.79 or newer (Chrome stable security updates; we ship .47), built on the Hill Studio's own Chromium checkout. Owner: build there and ship in 0.2.2 (2026-11-03) | planned |
| GitHub security alerts cleared: Dependabot (image-size, minimatch, deepmerge) bumped, the omnibox quick-create regex no longer slows on crafted input, test-script CodeQL alerts fixed or dismissed | in progress: CodeQL #201 (quick-create regex) and #200 fixed in 1161a442; the build-time Dependabot alerts (no usable fix) and the test-only CodeQL alerts wait on the owner's dismissal |

## 0.3.0: the CLI and Raycast revamped, and tabs that cost less

| Item | Status |
|---|---|
| Revamp the `solara` command (apps/cli, docs/cli.md): scope to be set with the owner; its connection to the app is built in Swift (settings and keybindings from files, a local control socket, event hooks), not on the JavaScript side | planned |
| Revamp the Raycast extension (extras/raycast-solara) against the revamped CLI | planned |
| Publish the extension on the Raycast Store: meet its review guidelines and submit to raycast/extensions (a public PR in another project, so it needs the owner's OK at submission) | planned |
| Video call pop-out (Google Meet and others: the floating window a call opens, document picture-in-picture): make getting back to the call's tab easy and obvious; first find out what that window lets us change | planned |
| Tab discarding (highest priority of the performance items): Chromium's memory saver unloads background tabs and wakes them on click, with site exceptions and protection for tabs playing audio, holding a form or in a call; reconcile with Solara's existing sleeping tabs | in progress: the engine layer landed 838681e6 (Chromium's reasons a tab can't sleep, sleeping only an eligible tab, per-profile site exceptions); the app's use of it is next |
| Heavy tab detection: Chromium's detector flags a tab using too much CPU or memory; Solara badges it (native badges, replacing the React Native tab badges) and offers to put it to sleep | planned |
| Per-tab CPU and memory attribution: Chromium's resource attribution splits a shared process's cost between its tabs | planned |
| Memory use per tab on hover cards (native) | planned |

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
| Native bookmarks bar, with the native bookmark coordinator (see backlog) | planned |
| The New Tab page's remaining React Native parts: Personalize, the feedback check-in and the release postcard | planned |
| A native frame for extension popups | planned |
| Native site controls and prompts (permissions, autofill, translate, zoom, developer mode) | planned |
| Native extensions toolbar, overlays and side panel | planned |
| Native media: sidebar player, hover player, cast and share pickers, tab badges | planned |
| Native peek, Little Solara, calendar and meeting cards | planned |
| Native top tab strip, split chrome, swipe overlay and the rest of the layout surfaces | planned |
| Sidebar on the right: a Left/Right position in Settings, the View menu and the sidebar's menu; peek, resize, hover cards and drops mirror; the window buttons stay top left (as in Arc and Zen); built with the layout port, so it's written once, in Swift | planned |

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

## 1.1.0: a VPN per profile

| Item | Status |
|---|---|
| Attach a WireGuard configuration to a profile (import a .conf or paste one; the private key lives in the Keychain, never in sync) | planned |
| A WireGuard tunnel inside Solara, in userspace with no system VPN or admin prompt (wireguard-go or boringtun), one per configuration, exposing a local proxy only Solara can reach | planned |
| Route all of the profile's traffic through it: Chromium's per-profile proxy (pages, extensions, downloads, service workers) and WebKit's per-data-store proxy; Solara's own requests for that profile go through it too | planned |
| No leaks: DNS resolves through the tunnel, WebRTC is forced through the proxy, HTTP/3 falls back to TCP, and a tunnel that drops stops the profile's traffic rather than letting it out; leak tests for DNS, WebRTC and the visible IP | planned |
| A connected / connecting / failed indicator in the profile's sidebar | planned |

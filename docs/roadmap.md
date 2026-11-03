# Roadmap

What ships in the next few versions. The owner decides what moves onto it; everything unscheduled stays in
[backlog.md](backlog.md). Statuses: planned → in progress → landed (hash) → shipped (version). An item that moves to
another version leaves this one; a dropped item goes back to the backlog.

At each release, mark that version's items shipped, move anything unfinished to the next version or back to the
backlog, and check this file against the release notes.

## 0.1.4: updates you can see, shortcuts that win

| Item | Status |
|---|---|
| "New Solara Version Available" pill in the sidebar (toolbar with horizontal tabs) and "Restart to Update Solara" in the app menu, on a background download | in progress |
| The active pinned tab is obvious: flat inactive tiles, the active one raised and tinted with its icon's colour | planned |
| Tab, profile and window shortcuts win over pages (Google Sheets); per-shortcut Prefer Solara / Prefer Website / Use Both in Settings › Shortcuts | in progress |
| Security fixes in shipped code (CodeQL #101, #104, #160, #162–167) | landed (c2a9d598) |
| Security fixes in test tooling (31 alerts) and dependency overrides | landed (test tooling 29023ae2; the overrides with this row) |
| Alert re-scan and the approved dismissals (#6, #7, #34, #105, #106, #136) | planned |
| Perf ratchet runs again ("dev harness never answered" on 0.1.2 and 0.1.3) | planned |
| Fixes from the owner's two-Mac sync-join test of 0.1.3 | waiting on the test |

## 0.2.0: the sidebar your way, and a fresh engine

| Item | Status |
|---|---|
| Icons-only sidebar rail, 84 pt: drag-to-snap, View menu and Settings toggle, hover × to close, loading and audio badges, the address bar moves to the toolbar | drafted (~/.cache/solara-lead/work/r14/rail: rail.patch on be7b9864, NOTES.txt, 7 review findings open), not landed |
| Folder and group popovers, footer profile switcher, the hidden sidebar's peek in rail mode | planned |
| Sidebar on the right: a Left/Right position in Settings, the View menu and the sidebar's menu; peek, resize, hover cards and drops mirror; the window buttons stay top left (as in Arc and Zen) | planned |
| Engine: Chromium 156.0.8078.79 or newer (Chrome stable security updates; we ship .47). Needs a Chromium sync and rebuild: owner approved for 0.2.0 | planned |
| Update safety: never move or delete staged updates ourselves; drop a staged nightly only through Sparkle's Skip; quit holds 8 s at most | planned |
| Share… in the page's right-click menu and File › Share (⌥⌘S): selected text, an image, a link with trackers removed, media, the page (engine change) | planned |
| A full emoji picker for profile, tab and folder icons (search, categories, symbols), and names that save on click-away | planned |
| Little Solara can keep new-tab links inside itself (a setting) | planned |
| Tabs moved to another window land where a new tab would open | planned |
| New Window opens on the profile you're in | planned |
| Closing the last tab keeps the window while it has pinned tiles or a pinned group | planned |
| A muted tab's or site's notifications make no sound | planned |
| The hidden sidebar doesn't peek out while another app is in front | planned |

## 0.3.0: the CLI and Raycast revamped, and tabs that cost less

| Item | Status |
|---|---|
| Revamp the `solara` command (apps/cli, docs/cli.md): scope to be set with the owner | planned |
| Revamp the Raycast extension (extras/raycast-solara) against the revamped CLI | planned |
| Publish the extension on the Raycast Store: meet its review guidelines and submit to raycast/extensions (a public PR in another project, so it needs the owner's OK at submission) | planned |
| Video call pop-out (Google Meet and others: the floating window a call opens, document picture-in-picture): make getting back to the call's tab easy and obvious; first find out what that window lets us change | planned |
| Tab discarding (highest priority of the performance items): Chromium's memory saver unloads background tabs and wakes them on click, with site exceptions and protection for tabs playing audio, holding a form or in a call; reconcile with Solara's existing sleeping tabs | planned |
| Heavy tab detection: Chromium's detector flags a tab using too much CPU or memory; Solara badges it and offers to put it to sleep | planned |
| Per-tab CPU and memory attribution: Chromium's resource attribution splits a shared process's cost between its tabs | planned |
| Memory use per tab on hover cards | planned |

## 1.0.0: all Swift

React Native and Expo are gone: the app is Swift on SolaraCore, with no JS runtime, no Hermes, no Metro and no
Expo modules. Settings, onboarding, Import, New Tab, the omnibox, internal pages, the link bubble and the store are
already native (RN removal 01–08).

| Item | Status |
|---|---|
| Inventory what still runs in React Native (apps/browser/src) and order the ports | planned |
| Port the remaining RN surfaces to Swift (bookmarks bar and the native bookmark coordinator first; see backlog) | planned |
| Remove Expo, react-native-macos, Hermes and Metro; the Xcode project builds without Pods for JS | planned |
| Move the repo from pnpm to Bun where JS tooling remains (backlog, after RN is removed) | planned |
| Perf: the speed comparison against the previous stable, deferred since 0.1.0 | planned |

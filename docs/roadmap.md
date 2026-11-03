# Roadmap

What ships in the next few versions. The owner decides what moves onto it; everything unscheduled stays in
[backlog.md](backlog.md). Statuses: planned → in progress → landed (hash) → shipped (version). A cut item stays here
with its reason until the version ships.

At each release, mark that version's items shipped, move anything unfinished to the next version or back to the
backlog, and check this file against the release notes.

## 0.1.4: updates you can see, shortcuts that win

| Item | Owner | Status |
|---|---|---|
| "New Solara Version Available" pill in the sidebar (toolbar with horizontal tabs) and "Restart to Update Solara" in the app menu, on a background download | u14 | in progress |
| The active pinned tab is obvious: flat inactive tiles, the active one raised and tinted with its icon's colour | u14 | planned |
| Tab, profile and window shortcuts win over pages (Google Sheets); per-shortcut Prefer Solara / Prefer Website / Use Both in Settings › Shortcuts | k14 | in progress |
| Security fixes in shipped code (CodeQL #101, #104, #160, #162–167) | r14 | in progress |
| Security fixes in test tooling (31 alerts) and dependency overrides | r14 | planned |
| Alert re-scan and the approved dismissals (#6, #7, #34, #105, #106, #136) | lead | planned |
| Perf ratchet runs again ("dev harness never answered" on 0.1.2 and 0.1.3) | u14 | planned |
| Fixes from the owner's two-Mac sync-join test of 0.1.3 | — | waiting on the test |
| Icons-only sidebar | — | cut 2026-11-03: too costly for 0.1.4; moved to 0.2.0 |

## 0.2.0: the icons-only sidebar

| Item | Owner | Status |
|---|---|---|
| Icons-only sidebar rail, 84 pt: drag-to-snap, View menu and Settings toggle, hover × to close, loading and audio badges, address bar as a magnifier | r14 | drafted (work/r14/rail), not landed |
| Folder and group popovers, footer profile switcher, the hidden sidebar's peek in rail mode | — | planned |

## 1.0.0: all Swift

React Native and Expo are gone: the app is Swift on SolaraCore, with no JS runtime, no Hermes, no Metro and no
Expo modules. Settings, onboarding, Import, New Tab, the omnibox, internal pages, the link bubble and the store are
already native (RN removal 01–08).

| Item | Owner | Status |
|---|---|---|
| Inventory what still runs in React Native (apps/browser/src) and order the ports | lead | planned |
| Port the remaining RN surfaces to Swift (bookmarks bar and the native bookmark coordinator first; see backlog) | — | planned |
| Remove Expo, react-native-macos, Hermes and Metro; the Xcode project builds without Pods for JS | — | planned |
| Move the repo from pnpm to Bun where JS tooling remains (backlog, after RN is removed) | — | planned |
| Perf: the speed comparison against the previous stable, deferred since 0.1.0 | — | planned |

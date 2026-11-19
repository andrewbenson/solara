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

## 0.4.4: fixes, the glass New Tab bar and a tighter profile swipe (shipped 2026-11-18)

The sidebar and tab strip deciding in Swift moved to 0.4.5 with the rest of this version's unfinished rows.

| Item | Status |
|---|---|
| Fix (user report 2026-11-17, 0.4.1 and later): with the address bar in the sidebar, ⌘L and clicking the sidebar search bar do nothing until the sidebar is resized; suspected JS/native disagreement on icons-only (JS treats width 84 as the rail) | landed: omnibox-test's restored-84-point check fails on main and passes with the fix (VM); omnibox 19/19, sidebar-chrome 20/20, newtab 6/6; SidebarRowReuse 10/10 on the Hill Studio |
| Fix (owner 2026-11-17): swiping between profiles feels less smooth in 0.4.3 than 0.4.2; measure native swipe frames 0.4.2 vs 0.4.3, bisect (suspects e87b9a2e profile bar, fbd60886 lower fade), fix, and add a native swipe-frames row to the gate | landed: the highlight follows the swipe again as in 0.4.2 (0 mismatched frames vs 1-14 on main), the profile bar stops relaying its icons each tick; timing at 190 and 300 pt, trackpad and wheel, within 0.4.2's range (Hill Studio, 5 launches each); firmer haptic a299416a |
| ⌘L opens the Command Bar on the first press by default, as in Chrome (owner 2026-11-17): Open Command Bar defaults to Prefer Solara instead of Use Both; a choice already made is kept | landed: precedence 27/27, presses 108/109, omnibox and newtab identical to main (Hill Studio, two runs each) |
| top-strip-test runs to the end on main (it stops at "show of undefined", then at the peek's accessibility span), so the full-screen island can be checked against a real baseline (owner chose this over landing pass 9, 2026-11-17) | landed: four fixes; top-strip now runs to the end on main (26/33 on the Hill Studio, the 7 docked-strip leading-profile checks fail without the island); tab-drag 46/49 same as main |
| The New Tab bar in Liquid Glass (owner 2026-11-17): NSGlassEffectView in place of the flat plate, the sun rising behind the glass, every animation kept; three variants for the owner to pick from (stills and recordings) | landed: A (glass bar, sun rising behind it), buttons fixed, tall results checked over default, gradient and photo in light and dark; newtab 6/6, omnibox 19/19 (Hill Studio) |
| The profile tooltip's keycaps center their keys (owner 2026-11-18) | landed: e1f5b7e9 |
| A firmer haptic as a profile swipe crosses into the next profile (owner 2026-11-18) | landed: a299416a |

## 0.4.5: the data layer is native

Done when JavaScript holds no state of its own.

| Item | Status |
|---|---|
| Full-screen island like Rex's: 80 x 33 capsule, slides down and back up, no hover through to the sidebar's profile button, button glyphs on hover, minimize grey | moved from 0.4.4 (2026-11-18): rebased on main (work/isl44); main runs top-strip 26/33 with the same 7 docked-strip failures (32.7%); the island run timed out before its top-strip pass, and hidden full-screen captures show no glyphs on hover yet |
| macOS's one-time-code AutoFill panel stays off the New Tab bar and the Command Bar (seen 2026-11-18: a blank glassy panel over the results in about 1 in 12 launches, on 0.4.3 too). The app-wide opt-out works (0 of 24 launches) but would take macOS's codes from Messages away from websites too; owner: block it on our own fields only. Candidate and repro in the Hill Studio job otp44 | landed: our address fields declare contentType .URL, so macOS skips its code offer on them; 0 panels in 24 launches vs the panel on main, web pages still reach the offer; newtab 6/6, omnibox 19/19, shortcuts presses 109/109 as main (Hill Studio) |
| Tab and window drag and drop, folder and group actions in Swift | moved from 0.4.4: planned |
| The sidebar's and the top strip's actions in Swift: selection, close, rename, pin and move | moved from 0.4.4: planned |
| Media, extension, prompt and translation lifecycles in Swift; the TypeScript fallback reducers retire | moved from 0.4.4: planned |
| Closing a tab goes back to the tab you used before it, as in Arc; Back on a tab a link opened closes it and returns to its opener (seen in Ardia, 2026-11) | moved from 0.4.4: planned |
| Shortcuts: ⌃Tab / ⌃⇧Tab step down and up the sidebar list; ⌥⌘← / ⌥⌘→ switch profiles; ⌘1–9 count a collapsed group as one row; ⇧⌘C copies every selected tab's link (seen in Ardia, 2026-11) | moved from 0.4.4: planned |
| The native window layout is the default again: tab switch, new tab and new window within 15% of 0.3.5 (0.4.0's candidate: 48 vs 40 ms, 143 vs 95 ms, 162 vs 102 ms), then the right sidebar ships with it | moved from 0.4.4: moved from 0.4.2 (owner 2026-11-16): after a62efaf5, layout on is switch 61 vs 40.5 ms, new tab 128 vs 95, new window 138 vs 105 against 0.3.5; also chase the default layout's new window, 148 vs 95 ms |
| + New Tab is the new tab: ⌘T, + New Tab, the strip's + and New tab opens: Command Bar select the + New Tab row itself and show the New Tab page, with no extra row; going somewhere (or typing in its address field) moves it into the list where new tabs go, with the open animation; ⌘T again while it's still empty settles the empty one into the list as a New Tab row and starts a fresh placeholder, so several ⌘T presses still give several New Tab pages; an untouched placeholder you switch away from is discarded (never saved, synced or offered by Reopen Closed Tab), while settled rows stay. With Below the current tab the placeholder shows under the current tab. Internally it's a real tab from the first ⌘T, so extensions see it as in Chrome (owner 2026-11-14) | moved from 0.4.4: moved from 0.4.2: six passes; drivers green but the first ⌘V after ⌘T ⌘W on an untouched placeholder is still lost (main passes), and ⌘T costs extra main-thread time under load. Last patch: native API 67 on 96a9e605 |
| 0.4.0's perf follow-ups: new window on screen 135 vs 97 ms, page-load and profile-swipe JS stalls (+57%, +18%), and the sheet-host harness's busy-dismiss failure (docs/perf/0.3.5-to-0.4.0.md) | moved from 0.4.4: in progress: native layout fixes landed (a62efaf5); default-path new window +55% vs 0.3.5 open; new window (default layout): page-created engine report reveals the window without waiting on pane roots, 161 -> 111 ms vs main, 124 vs 0.3.5 104 (landed) |
| Commands, menus and shortcuts in Swift, with window, focus and navigation handling | moved from 0.4.4: in progress: tabs and windows landed (4ffd5446); other groups per docs/native/commands-plan.md |
| Settings and Import actions call Swift directly, not a JavaScript round trip | moved from 0.4.4: planned |
| From 0.4.3's gate: the open-tabs ratchet counts rose without attribution (listenerCalls 8218 -> 8320, subNotified +0.65%; suspect 2565518a); trace them, and fix or attribute before raising ceilings | moved from 0.4.4: planned |
| Fix sheet-host's "ending busy must allow dismiss" (fails in every gate since 0.4.0) so a full host-harness run passes | moved from 0.4.4: planned |
| Carry a drag to another tab or profile (owner 2026-11-17): hold a dragged image or link over a tab or a profile slot to switch there, and ⌘1–9, ⌘⇧[ ], ⌃1–9 mid-drag if macOS delivers keys during a drag; drop lands on the new page | moved from 0.4.4: in progress |
| From 0.4.4's gate: JS synchronous typing 0.085 -> 0.122 ms and native session main-thread stall 2178 -> 3050 ms (n=2, contention during the run); rerun quiet with n>=5 and attribute (docs/perf/0.4.3-to-0.4.4.md) | planned |
| The Search Tabs panel in Liquid Glass, matching the New Tab bar (owner 2026-11-18): same glass surface, selection and divider tuned for glass, Reduce Transparency keeps the plate | landed: one glass panel per window, kept between opens; first open within main's range (7+7), reopen 16.7 vs 39.6 ms; tab-pickers 17/17 (Hill Studio) |
| The sidebar tab hover card in Liquid Glass (owner 2026-11-18): the card with the title, host, memory and pin/bookmark buttons gets the same glass as the New Tab bar and Search Tabs; Reduce Transparency keeps the plate | planned |
| The profile tooltip, smaller and in Liquid Glass (owner 2026-11-18): about a macOS tooltip's size next to the profile icons instead of a 34 pt pill, keycaps scaled to match, same glass as the New Tab bar | planned |
| The incognito New Tab page gets the same Liquid Glass bar and sun-rise animation as normal windows (owner 2026-11-18) | planned |
| The selected sidebar tab is easy to spot in every theme (owner 2026-11-18): Liquid Glass with a tint always lighter than the sidebar (computed per theme), its lit edge and a soft shadow; prototype variants A/B/C first, the owner picks | prototyping |
| Fix (owner 2026-11-18): the sidebar media player card's glass is so clear the tab rows behind it show through its title and buttons; regular glass, a stronger theme tint, an opaque card under Reduce Transparency | planned |
| The sync engine in Swift | planned |
| Legacy migrations in Swift | planned |
| The JavaScript mirror of the store is gone | planned |

## 0.4.6: React Native off by default

The app starts without React Native; it stays bundled as a fallback, switched off.

| Item | Status |
|---|---|
| The app starts without React Native; React Native stays bundled as a fallback, switched off | planned |
| Chromium engine update to 158 (owner 2026-11-18): Helium 0.22.1 / 0.22.1.1 on Chromium 158.0.8127.36 (today 157.0.8103.50 on Helium 0.21.2), on the Hill Studio only: rebase our patch series (series.py check), keep both Safe Storage patches unchanged, full engine build, publish-engine.sh, then the full suite and the stable gate. If Helium ships a newer 158 tag before then, take that | planned; owner approved the gclient sync and full rebuild on the Hill Studio (2026-11-18) |
| Protected video in the Chromium engine through Apple's FairPlay (Netflix, Disney+, YouTube films, Spotify) with a sandboxed AVFoundation helper, replacing the WebKit fallback; engine work, licence and sandbox review first (seen in Ardia, 2026-11) | planned |
| Picture in Picture: a click on the video's left or right side skips 10 s back or forward; thrown into a corner, its curve nests inside the window's corner (seen in Ardia, 2026-11) | moved from 0.4.5 (owner 2026-11-18): moved from 0.4.4: planned |
| Auto Picture in Picture for calls: Google Meet pops out when you leave its tab and comes back when you return (seen in Ardia, 2026-11) | moved from 0.4.5 (owner 2026-11-18): moved from 0.4.4: planned |
| Split View: double-click a divider to even the panes; an accent ring marks the focused pane; the resize cursor covers the whole divider (seen in Ardia, 2026-11) | moved from 0.4.5 (owner 2026-11-18): moved from 0.4.4: planned |
| Everyday tab actions from the command line: `solara open URL [--window] [--profile] [--background]`, `solara tab activate/close/reload/duplicate/mute/sleep`, close duplicates, sleep tabs idle for a while; never brings Solara forward unless asked (owner 2026-11-14) | moved from 0.4.5 (owner 2026-11-18): moved from 0.4.4: partly landed in 0.4.3 (open URL); tab actions by ID wait for an app-side ID map and sleep state |
| Profiles agents can't reach: a per-profile setting that keeps the `solara` command and MCP out of a profile, enforced by the app on the control connection, not by the command; new profiles allow agents by default; the command's history and pins reads move into the app so the setting covers them; listings hide blocked profiles' names and say only how many are closed to agents (owner 2026-11-14) | moved from 0.4.5 (owner 2026-11-18): moved from 0.4.4: design settled; build next |
| One Agents pane in Settings (Swift) for both the MCP server and the `solara` command: the master switch, per-profile access, and per app read-only or "can act"; "Add" for each agent app found (Claude Desktop through its own extension install, Claude Code, Codex and ChatGPT desktop through their shared config, Cursor and VS Code through their install links, the rest by copy or a reviewed file edit); every edit shows its lines first, keeps a backup, leaves other servers alone and has Remove; says when an app needs a restart. The MCP entry runs the command inside Solara.app, so nothing else is installed. ChatGPT on the web isn't offered: it needs a public endpoint (owner 2026-11-14) | moved from 0.4.5 (owner 2026-11-18): moved from 0.4.4: planned |
| The terminal command stays a separate, explicit choice: per coding agent "also let it use `solara` in the terminal (full control)", off by default, installing the command and its skill; plus the existing install for people. The app enforces scope: the MCP gets a read-only key unless actions are allowed, the command a full key, and the control connection refuses anything outside a key's scope or profiles (owner 2026-11-14) | moved from 0.4.5 (owner 2026-11-18): moved from 0.4.4: planned |
| Revamp the `solara` command (apps/cli, docs/cli.md): scope set with the owner 2026-11-18 (docs/cli.md › The revamp: one command table shared with MCP, actions on for the owner, settings and shortcuts as files, owner-placed event hooks, exec behind a toggle, window/profile/bookmark/download/config/pipe commands); its connection to the app is built in Swift (settings and keybindings from files, a local control socket, event hooks), not on the JavaScript side (moved from 0.3.0, owner 2026-11-04: after the port; moved up with the agents work, owner 2026-11-14) | moved from 0.4.5 (owner 2026-11-18): moved from 0.4.4: planned |
| Revamp the Raycast extension (extras/raycast-solara) against the revamped CLI (moved from 0.3.0, owner 2026-11-04: after the port; moved up with the agents work, owner 2026-11-14) | moved from 0.4.5 (owner 2026-11-18): moved from 0.4.4: planned |
| Publish the extension on the Raycast Store: meet its review guidelines and submit to raycast/extensions (a public PR in another project, so it needs the owner's OK at submission) (moved from 0.3.0, owner 2026-11-04: after the port; moved up with the agents work, owner 2026-11-14) | moved from 0.4.5 (owner 2026-11-18): moved from 0.4.4: planned |
| Air Traffic Control: links from other apps go to a chosen profile or tab group by URL pattern (Arc's; seen in Ardia, 2026-11) | moved from 0.4.5 (owner 2026-11-18): planned |
| Interface size: one setting scales Solara's own interface, not web pages (seen in Ardia, 2026-11) | moved from 0.4.5 (owner 2026-11-18): planned |

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
| New Tab image backgrounds in Personalize (owner 2026-11-17, low priority): pick any of the macOS wallpapers or a custom image of your own; a dim/blur control so the Liquid Glass bar and text stay legible, optionally a different image for light and dark; custom images sync as files with the theme, nothing fetched from the web | planned |

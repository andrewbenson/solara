# App store API (apps/browser/src/store)

One zustand store: `useBrowser` (store/browser.ts). Actions take explicit ids. Read the
modules before using them — this is a summary from the agent that built it.

## State
- `profiles` + `profileOrder`; default profile id is `"default"`.
- `windows`: `{ profileId, incognito, tabIds (sidebar order, pinned first), activeTabIds[profileId], sidebarOpen, frame, tabLayout?, fullScreen?, sidebarWidth?, sidebarIconsOnly?, sidePanelWidth? }` + `windowOrder`.
  A private window's `profileId` is `incognito:<window id>@<originalProfileId>` (`incognitoProfileId`, store/model.ts),
  `originalProfileId` the regular profile it was opened from (`createWindow({ incognito: true, profileId })`, default
  `lastActiveProfile`). Its engine profile (`engineProfile`) is that profile's off-the-record one: private windows of one
  profile share a session (`privateSession(profileId)`, the regular engine name), another profile's never. Downloads
  carry `offTheRecord` and their regular profile (`downloadSession`, store/ui.ts); a session's go with its last window.
- `tabs` (persisted) vs `live` (in-memory page facts, replicated on the native wire and never persisted).
  When Swift owns the workspace, each `live[tabId]` is `{ discarded, isLoading, canGoBack, canGoForward, playingAudio, themeColor }`;
  Swift owns every field, including `discarded` (default false). Progress and other presentation state remain JS UI state.
  JS consumes authoritative patches and full snapshot replacement; it does not fill idle entries, prune closed ids,
  copy holder/borrower facts or transfer facts for swaps. Swift normalizes those changes in each settlement.
- `groups`: `{ windowId, profileId, name, icon, color, collapsed, pinned, tabIds }` (members contiguous). `color` is
  `null` for Neutral, `"none"` for a transparent group, or one of Chrome's nine group colors.
- `splits` (store/splits.ts): `{ windowId, tabIds (2–3, pane order), orientation, sizes, stack? }` — `stack` = two panes sharing a slot the other way (Add Bottom Split). Members are contiguous in `window.tabIds`; the window's active tab is the focused pane. A split is one sidebar row (`splitRowPanes`): its panes are all unpinned, or all pinned rows; `placing`, `withGroup`, `createGroup`, `addTabsToGroup` and `removeTabsFromGroup` take every pane of a row they're given one of (`withSplitRows`), pinned panes are always rows, and a pinned split is mirrored to the profile's windows (pinMirror) and parked with them (`ParkedPins.splits`). `window.tabLayout` ("sidebar" | "top", unset = Settings).
- `history[profileId]`: a view of Chrome's history (HistoryService), one entry per URL, not saved; `historyReady[profileId]`
  once it has been read (lib/history.ts). `bookmarks`: `{ nodes, roots[profileId]: { bar, other } }`.
- `closedTabs` / `closedWindows` (full state; a closed window's entry leaves out its pinned tabs and pinned groups, and retains its optional tab layout, full-screen state, sidebar width, icons-only and side-panel width);
  `downloads`; `settings` (typed, store/settings.ts).
- `parkedPins[profileId]` (store/parkedPins.ts): pinned tabs belong to the profile's sidebar, as in Dia. Closing a
  window (⌘W on its last tab, the close button, ⇧⌘W, "Start fresh" on launch) parks its pinned tiles (at their pinned
  URL) and pinned groups, with their order and tab/group ids; the next window that shows the profile takes them back,
  unloaded (`createWindow` — ⌘N, the Dock, a link from another app, the first window after a relaunch —,
  `switchProfile`, Reopen Closed Window, ⇧⌘T of a tile's page), and the park empties, so nothing comes back twice.
  Only the last window of a profile parks: while another window shows the profile, the pins are there.
  Sync publishes parked pins as the profile's pins and applies changes to them in place (sync/adapters `pinnedAdapter`).
- Pins are per profile in every window (store/pinMirror.ts): each regular window showing a profile holds its own copy
  (a Tab, a TabGroup) of every pinned tile and pinned group, linked by `pinKey` (unset on the first copy, whose id is
  the key; `pinKeyOf`). A store listener (`mirrorPins`) carries a change of one window's pinned section to the others
  (the focused changed window wins) and gives a window that starts showing a profile its pins (the union, for windows
  that differ at launch). Copies it makes are unloaded; a copy it drops goes if it never loaded, else stays as a regular
  tab. Moving a pinned tab between windows (`moveTabsInto`, an extension's move) leaves a copy behind
  (`settleMovedPins`). Sync keys pins by `pinKey` and changes the home window's copy.
- Tile folders (store/tileFolders.ts): a pinned tile's `tileFolder` (`{ id, name }`) puts it in a folder tile in Top Apps; a
  folder is the tiles of a window that share an id, kept next to each other in the window's order. `addToTileFolder`,
  `newTileFolder`, `leaveTileFolder`, `renameTileFolder` and `dissolveTileFolder` are pure (state in, state out);
  `placeTabs({ tileFolder })` sets it, `null` takes a tab out, and leaving it out keeps it. A tab that stops being a tile
  loses it, and a folder that drops to one tab dissolves (`settleTileFolders`, run with the pin mirror). It never reaches
  Chrome: members are plain pinned tabs there. Mirrored, parked and synced with the pins (`tilefold:` records).
- UI: `ui.focusedWindowId`, `ui.focusOrder`, `ui.lastProfileId` (the regular profile of the window used last, a private
  window counting as its `originalProfileId`; saved with the session; read it through `lastActiveProfile(s)`, store/small.ts),
  `ui.appDark`, `windowUi[windowId]` (command panel, downloads popover), `find[tabId]`. `find`, `ui.appDark`,
  `windowUi`, `selection` and `selectionAnchors` are Swift-owned and not persisted; Swift prunes them when their tab
  or window goes, and activating or opening a tab closes the window's panel, grouping clears its selection and a new
  download opens the focused window's popover in the same commit.

## Actions
- Windows: `createWindow`, `closeWindow`, `switchProfile`, `moveTabsToWindow`, `moveTabToProfile`,
  `mergeAllWindows`, `reopenClosed` / `reopenClosedTab` / `reopenClosedWindow`, `restoreClosed`.
  Little Solara (Little Arc): `createWindow({ small: true, url })` makes a `kind: "small"` window with one tab (store/small.ts),
  in `lastActiveProfile(s)` unless `profileId` says otherwise; never private.
  `newTab` into it goes to `mainWindowFor(s, profileId)`; `resolveWindowId(s, null)` never picks it; closing it records a
  `ClosedTab` with `small: true` that reopens in a new Little Solara; it isn't saved with the session.
- Tabs: `newTab(windowId, { url, background, adoptId, openerId, profileId, pinned, index })`, `closeTabs(ids, { lastClosesWindow })`
  and `closeTab(id)` (the same path with `lastClosesWindow`, for ⌘W and ✕), `activate`, `navigate`, `updateTab(id, patch)`,
  `togglePin`, `moveTab`, `moveTabBy(id, ±1)` (both within the tab's pin section), `duplicateTab`, and
  `faviconChanged(id, favicon)`. When Swift owns the workspace, native `pageReport` interprets URL/title and live
  together; JS `navigated`/`updateLive` and the third `updateTab` live argument cannot write those facts. Those reducers
  retain their existing behavior when the native workspace is off. Chrome records visits (HistoryService) and icons (FaviconService).
  Closing a pinned tab only unloads it (`unloadPinnedTabs`, like Dia): the tile stays with `unloaded: true`, back at its
  pinned URL and without a web view until selected; the window selects its last-used regular tab, else the loaded
  pinned tab it showed last, else a New Tab page, and ⇧⌘T restores the page into the tile. Closing the last tab closes
  the window, unloaded pinned tiles aside (`closesWindow`), so holding ⌘W ends there instead of waking them. Unpin
  removes a pinned tab. A tab of a pinned group (Dia's pinned container, `inPinnedContainer`) unloads the same way, on
  the page it showed, and stays in its group. Both close calls run one rule set (`closingTabs`): a Peek tab ends the Peek,
  pinned tabs unload, and a window whose shown tabs all go gets a New Tab, or closes when `lastClosesWindow` is set
  and the New Tab bar policy doesn't keep it (`leavesEmptyWindow`). `closeIntent(s, tabId)` says what ✕ does
  (close, unload with the pages it shares, or remove a closed pinned row); the last-tab confirmation stays in
  lib/actions.ts.
  `duplicateTab` and Reopen Closed Tab set `adoptId` to `clone:<tab id>` / `restore:<tab id>` (`ClosedTab.tabId`):
  the engine copies or restores that tab's back/forward list, else the tab loads its URL.
- Import: `importWorkspace({ profileId, theme?, pinnedAgainst?, windows })` is one native command and one commit.
  Swift mints every window, tab, group and split id. Each window draft has `windowId?` (an existing regular window),
  `newWindow?`, `tabs`, `group?`, `groups?`, `splits?`, `drafts?`, `pinnedAgainst?` and `skipExistingOpen?`.
  Without a target it uses the most recently focused regular window, then the first regular window, then creates one;
  `newWindow: true` always creates a window. Tabs carry `{ url, title, pinned?, row?, customTitle? }`.
  Only HTTP, HTTPS and file URLs are imported. URL duplicates are skipped against native state, including parked pins
  and pin homes; `pinnedAgainst: "tiles"` compares pinned tabs only with tiles outside groups, while the default
  `"anyPin"` includes pinned rows and pinned groups. Unpinned tabs compare with every open or parked page.
  `skipExistingOpen: true` also excludes already open or parked pages when importing pins, as Dia requires.
  Window drafts run in order, so later drafts see tabs made by earlier drafts. New unpinned tabs follow the configured
  insertion position and retain their source order; pinned tabs use the pinned insertion position.
  `group` names a group for the new unpinned tabs. Explicit groups carry `{ name, tabIndices, pinned? }` and splits
  carry `{ tabIndices, orientation? }` (`"horizontal"` or `"vertical"`). Indices refer to the draft's original tabs;
  skipped tabs are omitted from groups and splits, and a split with fewer than two surviving panes is omitted.
  Groups cannot overlap or contain individually pinned tabs. Splits cannot overlap or cross group or pin sections.
  `drafts` accepts nested `{ title, children }` folders and `{ title, url, customTitle? }` links as pinned groups.
  `theme` applies the imported profile theme in the same commit. The result is
  `{ tabs, skipped, windows, tabIds, groups, splits }`; `tabIds` lists new flat tabs per processed window draft.
  Imported tabs have no navigation or adopted page and stay unloaded until selected. The full payload is validated
  before state changes or id allocation, so malformed input leaves the workspace untouched.
  Bookmark, history, favicon, password, cookie and autofill import keep their existing owners.
- Groups: `createGroup`, `addTabsToGroup`, …
- Splits: `createSplit`, `openSplitPane(windowId, { tabId | url, anchorTabId, side, background })`, `replaceSplitPane`, `removeTabFromSplit`, `separateSplit`, `flipSplit`, `toggleSplitOrientation`, `movePane`, `focusPane`, `updateSplit`; `toggleTabLayout`; `setWindowLayout(windowId, "sidebar" | "top")` changes only that window, without choosing a global setting. UI entry points with Dia's feedback (max-panes toast, menus): components/layout/splitActions.ts (`openSplitPane`, `openNewTabInSplit`, `openInSplit`, `openLinkInSplit`, `showSplitMenu`). Drag a tab onto the page to split: components/layout/tabDrag.ts.
- Sidebar sizing: `setWindowSidebar(windowId, { sidebarWidth?, sidebarIconsOnly?, sidePanelWidth? })` changes the target window
  and chooses the matching global defaults (`sidePanelWidth` uses `settings.extensionSidePanelWidth`). Before choosing each
  global, every other window without that override is pinned to its current effective value, except Little Solara. New windows inherit
  the latest globals. Optional window values fall back to Settings, then the built-in defaults; these values remain local
  and unsynced. A non-sync `updateSettings` containing `sidebarIconsOnly` clears every window's icons-only override so
  Settings applies to all windows.
- Sidebar organization (store/organize.ts): `selection[windowId]` with its ⇧-click anchor `selectionAnchors[windowId]`, both set by
  `clickTab(windowId, tabId, mods)` (plain, ⌘ and ⇧ clicks, ⌥⇧ into the shown tab's group), `placeTabs(ids, { pinned, row, beforeId, groupId, last })`
  (`last` puts a row with no `beforeId` after the pinned groups too). Drag and drop in the sidebar and the top strip
  goes through store/drops.ts: a view turns the pointer into a `DropSpot` (zone plus the tab it lands before),
  `resolveDrop(s, source, spot)` gives the `Drop` (or refuses it), `dropTabs(ids, drop)` applies it, `movingTabIds` is
  the set that moves together, and `slotDrop` turns a strip slot index into an anchor. `pinTabs(ids, pinned, row?)` (a pinned tab is a Top Apps tile, or a pinned row above the tabs when
  `tab.pinnedAsRow`; windows order tiles, then pinned rows and pinned groups in one interleaved order, then the rest; `row` omitted keeps a pinned
  tab's kind and pins a new one as a tile). A live folder sits in that pinned order by `LiveFolder.after`, the anchor key
  (`t:` or `g:` plus the pin key) of the row or group just above it, or `null` for the top (components/sidebar/pinnedOrder.ts);
  when its anchor goes it moves under the item that was above the anchor. Also pinned base URLs (`tab.pinnedUrl`, `returnToPinnedUrl` ⌘↩, `setPinnedUrl`; set on tiles, pinned rows and tabs in pinned groups alike, and cleared when a tab leaves every pinned place, by the `settlePinHomes` listener in store/pinHomes.ts), `setSiteMuted` (Mute Site,
  `settings.mutedSites`; a private window's mutes stay in `privateSiteMutes[windowId]`, in memory), `groupTabs` (pinned by default, like Dia), `moveGroup`, `duplicateGroup`, `newTabInGroup`,
  `closeGroup` → `closedGroups` (History › Recently Closed Groups; `restoreClosed` takes their ids), `moveGroupToBookmarksBar` (lib/bookmarkGroups.ts, async: files the group through bookmarkWriter and closes it only once the bookmarks are accepted),
  `cleanUpTabs` → `cleanedTabs` / `restoreCleaned(entryId?, windowId?)` (a private window's go to `privateCleanedTabs[windowId]`,
  in memory, and only back into that window; read either with `cleanedTabsFor(s, windowId)`), `closeAbandonedNewTabs`. `newTab` with `openerId` + `background` (⌘-click)
  joins the opener's group (`settings.cmdClickCreatesTabGroup`). Sidebar UI lives in components/sidebar/.
- Profiles: `createProfile` (`shareWith`: share another profile's data), `updateProfile`, `deleteProfile`, `reorderProfiles`, `setDefaultProfile`.
  `deleteProfile` queues engine data no profile uses any more in `orphanedProfileData` (saved); lib/profileData.ts deletes it
  (`deleteProfileData`, which erases the original profile's data through Chrome's own stores) and retries at launch until it's gone.
  Shared data: `profile.dataId` names the data a profile uses; `engineProfile(id)` resolves it, bookmark roots are the same
  folders, and store/profiles keeps history lists identical (`dataGroups`, `sharingProfiles`). The Create Profile dialog is
  components/profiles/CreateProfile.tsx (`lib/actions.createProfile`).
- Bookmarks: UI callers await `bookmarkWriter` (`addBookmark`, `addBookmarkFolder`, `updateBookmark`,
  `moveBookmark`, `removeBookmark`, `toggleBookmark`, `addBookmarkTree`, `removeBookmarks`, `restoreBookmarks`).
  Receipts resolve after durable native acceptance; callers refresh the current native projection rather than
  installing a receipt's old document. Synchronous JS slice methods refuse bookmark authoring.
  `NativeBookmarkOwner` owns desired documents, edit facts and engine/profile route lifetimes; `BookmarkPump`
  alone reads and applies Chrome trees. JS subscribes to the aggregate native projection. Shared aliases display
  one engine revision; removed routes cannot retain old roots. `hasView` permits display; `readyForSync` alone
  releases bookmark sync. Roots remain `bar@<engine>` / `other@<engine>` and nodes retain Chrome UUIDs and sync keys.
  The native journal outranks the display cache. Migration preserves the legacy source and keys until every
  engine has successfully pushed and confirmed a read; reopening 0.3.0 resumes the checkpoint without reimporting
  consumed source identities. Safe mode uses the read-only decoder, keeps show/open available and pauses
  bookmark edits, migration, cache saves and sync. Evidence is never cleared by a recovery launch.
  Distribution always selects native ownership. Development opt-in requires an explicit isolated data folder;
  ownership-off, partial native workspace scope and missing capabilities mean unavailable bookmarks with no JS writer.
  Downgrading to 0.2.5 is unsupported; there is no handback or downgrade marker.
- History (Chrome's; lib/history.ts reads it and follows its `history.changed` events, and moved the old `history.json`
  into it once): `removeHistory` (deletes from Chrome too), `clearHistory(profileId, since?)` (the view; Clear Browsing
  Data deletes from Chrome), `importHistory` (Chrome's importer path). Favicons are Chrome's too: lib/favicons.ts is
  an in-memory cache by page, plus the icons live tabs show and the light/dark pick. Settings: `updateSettings`
  (`bookmarksBar`, `shortcuts` = remapped menu keys read by Menus.swift, …).
- `setAppDark(dark)`: updates `ui.appDark` from the native appearance observer; the JS action is a no-op when Swift
  owns the workspace.
- `setFind(tabId, patch)`: merges per-tab find state onto closed defaults, synchronously through Swift when it owns
  the workspace; unknown tabs are ignored and removed tabs are pruned.
- `setSelection(windowId, ids)`: deduped and kept to the window's view; an empty selection removes the entry.
  `setSelectionAnchor(windowId, tabId)` moves the ⇧-click anchor (the native sidebar's own clicks).
  `clickTab(windowId, tabId, mods)` is one Swift command: anchor, selection, ⌥⇧ grouping and activation commit together.
- `openPanel(windowId, initialText?, newTab?)` (claims the command bar's focus first), `closePanel(windowId)` and
  `setDownloadsOpen(windowId, open)`: one `windowUi` entry per window, closing a panel that isn't open changes nothing.

## Hooks (store/hooks.ts, window-scoped)
`useWindowId`, `useActiveTab(Id)`, `useTab(id)`,
`useTabLive(id, select?)`, `useWindowProfile`, `useProfiles`, `useSettings(select)`, `useFind(tabId)`,
`useWindowUi`, `useIsBookmarked(url)`. Subscribe rows by id with narrow selectors so progress events
don't re-render every tab.

## Helpers and side effects
- Pure: store/model.ts — `viewTabIds`, `activeTabId`, `engineProfile` (the WebView `profile` prop), `windowTitle`.
- Dialogs / native side effects go through lib/actions.ts (`closeTab`, `switchToTab`, `moveTabToProfile`,
  `moveTabToWindow`, `createProfile`, `deleteProfile`, `openWindow`).
- Menu commands: lib/commands.ts (JS) + packages/shell/ios/Menus.swift (native menu bar).
- Tests: `pnpm --filter @solara/browser test` (`docs/testing.md`).

## Page reports, ownership and native events

`@solara/store` keeps one synchronous command transport: `nativeWrite({ name, args })`.
`pageReport(tabId, report)` sends `{ name: "pageReport", args: [tabId, report] }` and returns the usual
revision/patch/result/effects response. There is no second live mutation channel. `applyState` carrying `live`
throws before mutation. Owned JS `writeState.live` and direct guarded setState writes are refused before local
subscriber exposure; live is separate from writable owned slices. UI effects, sync busy/error handling, writable
UI keys and command-only slices keep their existing contracts. The compatibility `setPlayingAudio` command
still updates its cache, but JS no longer produces it for an owned workspace and native decisions use `live`.

The report types are:

| Type | Fields besides `type` and lifetime `generation` |
| --- | --- |
| `created` | `engine: "chromium" | "webkit"`, optional nullable `handoffSeq`, optional `reestablished`, and PageContext |
| `context` | PageContext |
| `issued` | nullable `navigation: { url, seq, userInitiated? }`, `startedEarly`, optional `sameProfileMove`, and PageContext |
| `navigation` | `url`, `title`, `isLoading`, `canGoBack`, `canGoForward`; optional nullable `themeColor`, optional `initialDocumentAccessed`, `committedInitial`, `committedUrl`, `eventSeq` |
| `media` | `playing`, optional `muted`, `eventSeq` |
| `ready` | `browserId`, optional `tabId`, `eventSeq` |
| `download` | optional nullable `committedUrl`, optional `skipped`, `eventSeq` |
| `discarded` | `url`, optional `eventSeq` |
| `failed`, `loadError`, `advance`, `gone` | optional `eventSeq` |
| `moved` | `sameProfile` |
| `restore` | startup-only, untagged `themes: [{ tab, page, color }]`; no active lifetime is created |
| `keepAlive` | `epoch`, `seq`, `handled`, `keep`, `reveal` |
| `latch` | `eventSeq` |

PageContext is `{ navigationSeq: number | null, contextRevision: number, wasNewTab: boolean,
newTabShownUrl: string | null }`. Optional report fields are absent when unsent; explicit null clears nullable
context. Context requires the current navigation sequence and a strictly newer revision. Issuance supplies
current context, including explicit null, and can reuse an equal revision only when its contents match.
The ordinary RN `pageContext` prop supplies context to native attachment before constructor reports; it carries no
identity or activation authority. Native attachment uses it only when its navigation sequence is current.
show/hide New Tab publishes context synchronously before updateTab or later navigation; asynchronous RN/pool
props supplement this publication. Loading A, Back to New Tab, then navigating to A clears the overlay even when
navigation's URL is unchanged. A no-op follow of the already consumed sequence preserves the overlay.
A stale prop cannot overwrite accepted newer context. Pooled creation validates cached context before attachment and engine construction; later appearance-only prop batches retain that context.

Swift interprets the existing pure TabPageModel and PageLive rules. Navigation commits URL/title and live in one
settlement; ready records `{ browserId, tabId? }` and clears discarded. Discard changes facts through reports and
keeps the producer identity, as does freeze. Gone retires the matching fence and resets surviving tab facts to idle.
A replacement starts with new ready/feed/latch/stamps and clears discarded. Same-session ordinary document reports
remain ordered; there is no document-age filter. Each report in an array settles separately so loading/URL edges
remain observable. `LiveChange` retains `tabId`, `previous`, `current`, `url`, `profileId` and adds nullable
`previousGeneration`/`currentGeneration` session strings. Closing removes live and emits `current == nil`.
`observeLive(_:)` returns `(token, baseline: [String: PageLiveFacts])`; `observeLive(tabId:_:)` returns an optional
single baseline, and `unsubscribe(token)` ends either observation.

There are two independent generation fields:

- `registrationGeneration` is a positive process-wide monotonically allocated JS-safe native registration number.
  It changes on registration replacement; numeric calls retain the captured registration and never upgrade it by tab id.
- `sessionGeneration` is an opaque native producer UUID string, compared only for equality. Native attach/create
  mints it; JS/render/nativeID never choose it. Every owned descriptor/event carries both fields. External registry
  descriptors may have `sessionGeneration: null` and no Store facts. Existing `PageReport.generation`,
  `PageFacts.generation`, Store `livePages()` values and `onPageCreated.payload.generation` retain their string
  session meaning. `eventSeq` is an independent per-session native stamp, not either generation or a feed epoch.

The native host registers each binding through PageRegistry.shared and installs its after-ingress deliver hook
before registration. Failed installation traps in Debug and logs/refuses registration in Release. Committed RN
mount attachment establishes Store memory and mapping before constructor events. Speculative React render does
nothing. Attach is idempotent for the same current native mount; logical detach/runtime retirement is exact and
precedes gone/close. Temporary visual reparenting retains authority. Replacement and transfers in both directions
retire the source session/registration before minting destination identities, preserving only confirmed physical
execution metadata. A late source callback, detach or old runtime teardown cannot claim or remove a replacement.
Pool sessions survive JS reload and discard/freeze. Pooled event/live descriptors include accepted `contextRevision`;
JS rebases its context clock above that value when adopting a retained producer after reload. Owned malformed or
missing-identity envelopes are rejected. Little Solara uses a pooled producer too.

RN's pre-Expo native tap reserves and settles facts before emitting UI events. Its private `storeReport` disposition
is `fallback`, `reserved` with the original session, or `rejected` with an optional original session. Rejected owned
events never become fallback. WebView checks disposition before decoding and checks current native authority again
when each held handler actually executes, including its captured registration. JS retains navigation following for
RN and UI effects for both hosts (history/favicon/prompts/status/media/overlay); pooled navigation following is native.
There are no duplicate JS created/gone/navigation/media/download/discard/ready writes on the owned path. Ready still records loaded profiles for resource release. Sleeping hooks read owned live.discarded; internal React pages complete semantic URL/title through updateTab without writing live facts.

Automatic sleeping is native by default (`LaunchSwitch.nativeTabSleep`). `status().nativeTabSleep` is the runner's
lock-backed running value, not just the launch switch; JS's `nativeTabSleepRunning()` also requires native workspace
ownership. While it is true, `lib/tabLifecycle` makes no automatic sleep decisions. The runner runs only while
`TabSleepPermissionFeed.servesPages`: its permission feed knows only pooled pages, so with the pool or the shell off
it stays off and the JS fallback decides, as it does with `SOLARA_NATIVE_TAB_SLEEP=0` in development or without native
workspace ownership. The `sleepInactiveTabs` setting is checked by both paths: a saved false stays off. JS still
feeds transient protections through `lib/nativeKeepAlive`, and retains battery saver, manual sleep and profile resource
release.

`updateRNPageContext(tabId, sessionGeneration, context): boolean` publishes only to the exact current attachment;
`isRNPageCurrent(tabId, sessionGeneration): boolean` is nonactivating. The shared RN/pool helpers
`isPageCurrent(identity): boolean` and `updatePageContext(identity, context): boolean` additionally validate the exact
`registrationGeneration` and `sessionGeneration`; JS uses them for held-event delivery and synchronous context
publication. Their native ABI takes tab id, session string, registration number and (for update) JSON context.
None creates identity. RN `issued`
returns a nonconsuming `{ actions, guard }` preview. PageIssueGuard contains `sessionGeneration`, complete nullable
`navigation`, `contextRevision`, `modelSerial`, `startedEarly`, `sameProfileMove`. Always finalize even an empty
preview using `finishRNPageIssue(tabId, guard): Promise<{ accepted: boolean }>` (the same native
`PageCommand.finishPageIssue` executor). JS never executes preview load/clear actions or clears on completion.
Native acceptance emits the matching UI clear before any engine-event UI notifications. The clear carries the consumed contextRevision and complete nullable navigation; JS clears only an overlay whose current revision and navigation still match. Rejected candidates leave
current following pending; JS retries a rejected completion once from the current request and coalesces intervening
follow requests. Owned `startNavigation` effects issue no raw JS load.

All legacy, G3 and typed native calls use one PageIssuer. Standalone `issue` enters Store.sequence;
`issueInScope` uses Store.withinSequence without a nested drain and requires existing ingress ownership (Debug
precondition, Release refusal). Its final body rechecks current tab/window/load/page eligibility, engine/profile,
exact binding/session/registration/fence, full navigation and accepted context, then consumes and invokes clear/load
synchronously outside core while holding ingress. No outward callback or intervening barrier can invalidate that
boundary. Pooled preparation is an immutable candidate; failed final consumption advances no followed marker.
Async completion/result waiting, main hops and callback delivery stay outside ingress/core.

A report enqueued inside a sequence body waits for the next barrier; sequence drains before the body and has no exit drain.

`nativePageFacts(tabId)` returns a copied nullable `{ generation, ready, keepAlive, latchedThrough, newestEventSeq }`;
`nativeLivePages()` returns the copied map for existing loaded RN/pool producers with active memory, including
not-yet-ready pages. These wrap native `pageFacts`/`livePages` JSON reads. Store reads, TabPool/module livePages,
registry descriptors/describe/snapshots and read-like page calls all capture after drain under the same barrier,
filter retired/unloaded/held entries and take ready from current Store facts, including null. They do not start or
close views. Returned copies describe their barrier; callbacks released after ingress may commit newer state before
the read returns to its caller. `deliveryCursor()` is a barrier read outside sequence and a no-drain read inside its
owning sequence; it reports committed revision and the last revision whose listeners have all finished.

`registerKeepAliveRuntime()` returns a new positive JS-safe numeric epoch, clears feed values and retains readiness,
generation, stamps, latch and anti-replay watermarks. Epoch starts at zero before registration. `keep` contains
boolean `capturing`, `newTabShown`, `pip`, `displayRequest` and `media: "none" | "present" | "playing"`;
`reveal` contains boolean `fullscreen`, `crashed`, `unresponsive`, `scrolledDown`, `sharing`.
keepAlive requires a current loaded tab/session, current positive epoch, positive safe integer seq, nonnegative
safe integer handled and a strictly increasing seq for that epoch/session watermark. Invalid/stale/missing-memory
feeds silently drop and never establish a page. Latch takes max(latchedThrough, eventSeq); stamped reports take
max(newestEventSeq, eventSeq). Feed/latch/runtime registration change Store memory only: no revision, patch,
persistence, effects or live listeners. Step 6 owns feed production and lifecycle policy; RN stays exempt from that
policy. 5b adds no JS lifecycle runner or download-started policy.

A keep fact the runner relies on must be set inside a page-event handler, before that event's `handled` is acknowledged, or be native. The runner refuses a page until `handled` reaches `newestEventSeq`, which native bumps when the event is emitted, so a fact set that way protects from the moment the page emits it. A fact set anywhere else can lag behind a sweep. `lib/nativeKeepAlive` flushes only when a tracked page's own inputs change, and retries pages still waiting on native facts (1 s, backing off to 30 s).

Unload/hydrate clears active page memory and live presentation; normalization restores idle entries and holder facts.
Nonretired producer fences and same-session watermarks survive retained ids; tab removal drops them, except bounded
close-held authority. Model serials remain monotonic across resets. Before refresh/following/facts, a trusted native
retained binding must prove current native routing/session/registration, eligibility and a matching nonretired fence,
then establish the same session with `reestablished: true`. Arbitrary reports cannot recover missing memory. Recovery
uses actual executed handoff sequence, never pending navigation, and fresh model/idle facts with ready/feed null and
latch/stamps zero; it replays no cached ready/feed. Its created event asks Step 6 to resend a full feed at its next seq.
Retired fences never recover; absent readiness remains protective until a real new ready report.

Close cancellation keeps structural snapshots free of live and separately retains affected transient facts plus
bounded held model seeds/fences (30 seconds, at most 10 windows). Matching held facts reduce FIFO into their existing
seed without creating tabs, commits, workspace/engine effects or feed values. Download/discard/failure update its
model/live; terminal close makes it non-restorable and gone removes authority. Restore preflights existing structural
and affected-live conflicts before mutation/undo consumption, preserves unrelated newer facts and atomically restores
surviving loaded projections/live/model/same-session authority under the new window id. Missing ordinary tabs stay
absent; unloaded pins stay idle. No old feed/latch/watermark or historical ready sequence is replayed, and no reload
is needed. A no-seed valid structural restore remains supported but requires trusted fence recovery before later
facts. Expiry, gone, consumed undo and hydrate release held authority. JS owns close-live undo only in fallback mode.

Native chrome uses the existing SidebarFlags: owned loading/audio/discarded come from BrowserState.live, including
an empty dictionary; nil alone selects fallback host arrays. Selection/developer/PiP/capture remain host presentation.
Contexts recompute facts without host prop changes and top-strip audio uses those same sidebar flags. Unloaded
fading remains separate from discarded sleeping.

The UI event queue (`lib/nativeEvents.ts`) still batches HELD_EVENTS in arrival order until a zero-delay timer or
another event/callback flushes them, then uses one React/store transaction. The queue retains only UI/fallback work
for owned producers. Native facts are already ordered before Expo; applyHeldReports after an await handles queued
JS UI work, not authoritative native fact admission. No input or page UI event is intentionally reordered or dropped.

## Replica retention, persistence and quit

One revision/cursor and one 65,536-patch ring carries workspace and live-only changes, including foreign commits.
Catch-up copies the requested suffix or a full snapshot and its exact revision together under ingress/core, then
encodes outside ingress. There is no separate live channel, cursor reconstruction or patch coalescing. Unlimited
suspension can exceed retention and uses snapshot fallback, which replaces live fully and preserves references for
equal JSON where possible. Hydrate consumes the native reset response rather than applying a second JS live reset.

Live, page memory, producer fences, generations, ready/feed values and watermarks never enter session documents,
SQL, sync records or schema migrations. Live-only commits do not schedule persistence; a URL/title change still does.
Native startup restores launch-look v2 themes before the first snapshot/render (maximum 1100*1024 bytes, 200 valid
themes, matching tab/page without hash, color at most 64 UTF-16 units), preserving an existing nonempty color.
Blank documents do not start grace; first matching settled nonblank navigation starts 1,500 ms. New color/page
cancels it; generation-checked native advance timers cannot clear a replacement. JS retains favicon seeding and saves
launch look by reading the replica.

Ordinary PersistenceWriter.flush reads committed state on its own queue and never enters ingress. Quit separately
runs a bounded report barrier on a dedicated non-persistence worker before writer flush. `flushForQuit` has independent
barrier/writer budgets, each 0.5 seconds by default; the JS/native flush(timeout) API retains its writer timeout plus
the independent 0.5-second barrier budget. Nonpositive budgets time out immediately. Barrier timeout starts no writer
and a cancelled late worker cannot start persistence later; accepted in-flight reduction can finish afterward without
a saved claim. Simultaneous quit flushes coalesce. Success covers reservations through the queue-empty check, not
future engine callbacks. Missing writer still drains, then reports skipped-safe-mode; failed/frozen/timedOut results
remain distinct. Total caller budget is the sum plus scheduling overhead. Teardown retires exact authorities; a
cancelled quit permits surviving bindings without reviving retired ones.

Safe mode can still own the workspace while using a settings/download-only writer or no writer. Its native reports
are ordered as usual, but workspace rows and session shadow remain untouched by persistence. If workspace ownership
is off, native reports/interpretation and pool availability are gated off and RN/JS fallback remains; there is no
native workspace projection.
The retired diagnostic scope is not reintroduced by page reports.

## Live tabs: Chrome's tab strips (lib/chromeTabs.ts, store/liveTabs.ts, packages/solaracore/src/tabStrip.ts)

One writer per fact. The store owns the **workspace**: sidebar order, pins, groups, splits, Little Solara, unloaded
and parked tiles, and which tab each window shows per profile (`activeTabIds`). Chrome's `TabStripModel` owns
the **live tabs**: which tabs each Chrome window ("strip": one per engine profile per app window) has, their order,
the active one, pins (and groups, once the engine reports them). JS never writes a live fact and never guesses who
caused a report: it sends commands with ids, the engine commits them in Chrome, and every change comes back as one
ordered transaction that names its cause. There are no echo windows, timers or "was that us" flags.

**The engine contract** (`@solara/solaracore`; SolaraCore implements it in `packages/solaracore/ios/SolaraCoreTabStrip.mm`):
- `sendTabStripCommand(command): number` sends a command and returns its id (unique for the app's lifetime, also
  across JS reloads). Commands:
  - `{ op: "activate", strip, key }`: make that tab the strip's active tab.
  - `{ op: "arrange", strip, keys, pinned }`: the listed tabs in this order at the start of the strip, the first
    `pinned` of them pinned and the rest not. Keys not in that strip (any more) are skipped; the strip's other tabs
    follow the listed ones.
  - `{ op: "group", strip, keys, group, title?, color?, collapsed? }`: the listed unpinned tabs into one of the
    strip's groups (its id), `"new"` for a new one, `null` out of theirs; the group's title, color and collapsed
    state when given.
- `onTabStripTransaction(listener)` delivers `{ rev, cmd, strips, rejected? }`:
  - `rev` is one more than the previous transaction's, for the engine's lifetime, in the order the changes were
    committed. A listener applies them in that order and drops any `rev` it has already passed.
  - `cmd` is the cause: the id of the command (each command yields exactly one transaction, also when nothing
    changed, with `rejected: true` when none of its tabs were in its strip); `-1` for the app's own engine calls
    that aren't commands (a WebView creating, restoring or duplicating its tab, a tab moving to another app
    window, a page command or DevTools activating its tab); `null` for what Chrome did on its own (an extension's
    `chrome.tabs`/`tabGroups` call, the tab Chrome shows after the active one leaves, a focus request selecting a
    tab, a strip's placeholder tab going).
  - A transaction never mixes causes. Chrome's pending changes go out before a command runs; whatever Chrome does
    synchronously inside a command (selection, observers) is the command's.
  - A change that isn't a command's and leaves its strip as it was last sent isn't sent (a new tab's insertion and
    placing made two identical transactions).
  - `strips` holds every strip the change touched, each whole: `{ strip, window, appWindow?, profile, tabs,
    groups?, activePickedOnClose?, closed? }` (`window` is shared by the strips of one app window, one per engine
    profile it shows; `appWindow` is the app's id for that window, its React root's `windowId`;
    `activePickedOnClose` says the active tab is the one Chrome picked because the active tab left the strip, not
    one anybody activated), `tabs` in strip
    order as `{ key, browser, index, active, pinned, group? }`, and `groups?: [{ id, title, color, collapsed }]`. `key` is the WebView's `transferKey` (the store's tab
    id), bound when a view first shows the browser and kept while the browser moves between views; `null` for a tab
    no view has shown (one Chrome made, before the app adopts it; an engine placeholder). `group` (Chrome's group id,
    null for none) and `groups` are absent while an engine doesn't report groups. SolaraCore reports Chrome's
    groups (the engine layer's `ac_tabs` in `//chrome/browser/solara`: event `tabs.strip`, call `ac_tabs_group`). A strip left without tabs is sent with `tabs: []`; a strip whose
    window closed comes once more with `closed: true`.
- `tabStrips()` answers every strip as a transaction with `cmd: null` and the last `rev` sent: the starting point
  after a JS (re)load. Transactions that arrive before it are held, then applied if newer.
- The engine never activates, moves or pins a tab for an app reason except on a command (no activation when a view
  becomes visible; a tab moved to another window goes there in the background). Showing a page still tells the
  engine where Chrome's views go (layout).
- A tab Chrome made in a window on its own (an extension's `tabs.create`) reaches the app as `onOpenWindow` with
  `adoptId: "tab:<browser>"`; a page's new tabs and popups come as `adoptId: "solaracore:<id>"`, already made by Chrome.

**How the app applies them** (lib/chromeTabs.ts): it keeps a mirror of every strip.
- A transaction with a `cmd` (the app's own) only updates the mirror: the store already holds that intent.
- A `null` one is Chrome's change, and `chromeChanged` (store/liveTabs.ts) makes the same change in the workspace,
  diffing each strip before and after it:
  - tabs whose order among the tabs that stayed changed (off the heaviest kept run; grouped tabs weigh more, so a
    tab moved into a group joins it rather than the group's tab leaving), or that Chrome pinned or unpinned, go
    where Chrome put them (a pane of a split keeps its pin, as in Dia: the split stays and Chrome is put back;
    `placing`, last to first, each before the next tab Chrome has after it that's already in
    place, keeping a group both neighbors share). A split is one row: its panes move together and nothing lands
    between them;
  - a new active tab that stayed in the strip is shown (`activate`'s rules, opener bookkeeping included), unless
    it's Chrome's pick of a successor (`activePickedOnClose`; from engines that don't say, any activation that comes
    with the old active tab leaving): then the store's own rule (store/openers.ts) decides. An explicit activation
    in the same change as the close (an extension's remove then update) is a switch, and wins over the store's
    successor command still on its way. A split's other pane and a tab of a profile the window isn't showing
    aren't shown (the focused pane changes on user focus; profiles keep their own tab);
  - a tab Chrome made (`tab:` adoption) takes Chrome's pin, place and activation the first time the app sees it;
    a tab arriving in a strip of another app window (an extension moving it; the window is `appWindow`, else the
    one its other tabs are in) changes window as it is, page and live state included (`intoWindow`; its view takes
    the same browser there), also into a window holding only New Tab pages;
  - groups, when the engine reports them: a tab Chrome put in a group or took out of one joins or leaves the
    store's group in place; a group Chrome made becomes a store group (title, color); a group's title, color or
    collapsed state follows. Chrome's group ids and the store's are bound in memory (`GroupBindings`);
  - Chrome's change to a fact that a command of the app's own, already sent to that strip, will set (the order
    and pins of the tabs an `arrange` lists, the groups of the tabs a `group` lists, the active tab for
    `activate`) is skipped: that command commits after it and wins.
- After every store change and transaction, `stripPlan` gives what the store wants each strip to be (the store's
  tabs in it in window order, pinned first; the shown profile's active tab) and the app sends the command that
  closes the gap: `activate` first, then `arrange`, then `group` (a Chrome group for a store group that has none,
  missing members, title, color (Neutral and `"none"` go as gray, and Chrome's gray back keeps them) and collapsed, as Dia's engine mirrors it; Chrome's model keeps the active tab when
  its group collapses);
  one command per strip at a time; no `activate` while Chrome's active tab has no key (a tab Chrome made in front,
  before the app adopts it: its activation is Chrome's, above); the same command isn't sent
  again until something other than the app's commands changed that strip (a plan Chrome can't reach doesn't loop).
- SolaraCore (`SolaraCoreTabStrip.mm`) takes the strips from Chrome's own tab strip models, which name the Browser, so a
  strip's window is never inferred from its tabs.
- Tests: `src/store/liveTabs.test.mjs` runs the real wiring against a fake engine that keeps this contract.

## Sync (apps/browser/src/sync, packages/sync)
- End-to-end-encrypted sync through a folder the user picks; design in `docs/sync.md`. `sync/engine.ts` owns the
  state (`useSync`: status, devices, other devices' tabs), the setup flows and the cycle; `sync/adapters.ts` maps the
  store to synced records (bookmarks, history, open tabs, pinned tabs and pinned groups, settings, passwords).
  Non-bookmark adapters rebuild or patch store state with `useBrowser.setState`. The bookmark adapter synchronously
  and durably accepts native replacements with record stamps before returning; refusal leaves the whole bookmark
  prefix and sync base unapplied. JS Cycle, transport, encryption and stamp minting remain in JS.
- Record keys use store ids (`bm:<id>`, `pin:t:<tab id>`), so ids must stay unique across Macs: `newId` has a random part.
- Tests: `src/sync/adapters.test.mjs` (two devices swap the one store; `docs/testing.md`).
  DEV: `acSync` (`turnOnSync`, `enterRecoveryPhrase`, `syncNow`, `stopSync`, `useSync`, `menu`, `sheets`).

## Dev tooling (DEV builds)
- LogBox is disabled (its shadows crash react-native-macos); console errors/warnings go to
  `$SOLARA_DATA_DIR/dev-console.log`.
- lib/devHarness.ts runs `$SOLARA_DATA_DIR/dev-eval.js` against the store — use it to drive a running instance.
- Menus per instance: scratchpad `axmenus` tool (System Events confuses instances sharing a bundle id).
- Swipes (layout/SwipeOverlay, layout/ProfileSwipe, packages/solaracore/ios/ACSwipe.mm): `globalThis.acSwipe.pane(tabId).devSimulate(steps, { ignorePreference: true })`
  and `.sidebar(windowId)` play synthetic trackpad gestures through the real tracker (pages scroll and ack for real); `acSwipe.history` opens the back/forward list.

## Internal pages, Settings, Import (components/pages, settings, import)
- `solara://history|bookmarks|downloads` tabs render React pages instead of a web view
  (`openInternalPage(page, windowId)`, `isInternalTab(tab)` in components/pages).
- Settings (⌘,) and Import are utility NSWindows with ids `settings` / `import` (`openSettings(pane)`,
  `openImport()` in components/settings/windows.ts); `runCommand` routes ⌘W there to close them.

## solara:// URLs (core appUrls.ts, like Dia's dia:// and Brave's brave://)
- **The app's form is `solara://`**, everywhere: `tab.url`, `navigation.url`, history, bookmarks,
  closed tabs, the bar, AppleScript. Nothing in the store is `chrome://`.
  - Input: `resolveInput` / `fixupUrl` turn `chrome://x`, `chrome:x`, `about:x` and `solara:x` into
    `solara://x`. about:blank and about:srcdoc stay as they are.
  - The engine boundary is packages/solaracore `WebView`. Loading maps `solara://` → `chrome://`
    (`url` prop, `loadUrl`). Reporting maps `chrome://` → `solara://` (navigation, open-window,
    popup, load-error, download and discard events, `navigationEntries`).
  - Pages linking to `solara://`: the engine (`ac_page_channel.h`) only follows these from a WebUI page (chrome://,
    devtools://) and drops them from web pages, like Chrome does for chrome://. That covers links,
    ⌘-clicks and popups.
  - Display: `urlForDisplay` / `displayUrl` / `breadcrumb` show `solara://version`, keeping the
    scheme and dropping a root "/". `tabLabel` (window title) and `hostLabel` (History / Bookmarks
    pages) show `solara://<host>`.
  - History is Chrome's, which doesn't record its WebUI pages (`solara://`).
- **Where each host goes** (`appUrlRoute`):

  | URL | Opens |
  | --- | --- |
  | `solara://history`, `bookmarks`, `downloads` | Our React pages in the tab (components/pages). They take precedence over Chrome's pages, and `chrome://history` typed or reported lands here too. |
  | `solara://settings` | Our Settings window (components/pages/appUrls.ts). The tab doesn't change. |
  | `solara://settings/<pane>` | Our Settings window at that pane: general, profiles (also `people`, `manageProfile`), sync (also `syncSetup`), tabs, appearance, privacy, passwords, autofill (also `addresses`, `payments`), extensions, search (also `searchEngines`), shortcuts, liveFolders, calendar, advanced. |
  | `solara://settings/<anything else>` | Chrome's settings page (e.g. `settings/languages`, `settings/content`). |
  | `solara://newtab` | A New Tab page (a new tab). |
  | `solara://extensions` | Chrome's extensions page (as dia://extensions is in Dia): developer mode, load unpacked, errors, shortcuts. Our Settings › Extensions stays at `solara://settings/extensions`. |
  | Everything else: `version`, `gpu`, `net-internals`, `flags`, `inspect`, `about`, `chrome-urls`, `password-manager`, `downloads-internals`, … | Chrome's WebUI page, shown as `solara://<host>`. |
- `settings` and `newtab` are handled in the store's `navigate` / `newTab` through `setAppUrlOpener`
  (store/tabs.ts). That covers every way a URL gets in: the bar, bookmarks, history, AppleScript,
  opened URLs and links. A restored tab at `solara://settings/…` loads Chrome's page.
- The OS doesn't route `solara:` to us. Like Dia and Brave, the app doesn't register the scheme,
  so a web page can't open `solara://quit` through Launch Services. `open -a Solara 'solara://version'`
  and AppleScript work, because those go to the app directly.

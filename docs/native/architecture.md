# Solara native architecture

This doc covers moving Solara off React Native and JavaScript to a native Swift app. It records what the app is
today (§1), what it becomes (§2), how the owner's data carries over (§3), how both stacks run side by side during the
move (§4), the plan phase by phase (§5), the measurements to take before any code moves (§6, details in
[baseline.md](baseline.md)), and the risks and open questions (§7).

The owner has already decided the following, and the doc designs for them:
- Fully native.
- All Swift, macOS first. The core is a Swift package (model, GRDB persistence, sync, omnibox, importers) built on
  Observation and strict concurrency. SwiftUI is used for forms and lists, AppKit for the sidebar, tab rows, drag and
  the toolbar. Chrome is reached through the existing C interface. Rust is out for now.
- Order: measure; the core becomes the source of truth behind a bridge; then Settings, New Tab, toolbar and omnibox,
  and the sidebar, one surface at a time; then RN, Expo, Hermes, Metro and the JS build are removed.

---

## 1. The architecture today

### 1.1 Processes and threads

| Where | What runs there |
|---|---|
| **Browser process, main thread** | `main.swift` → `SafeStorageRekeyRun` → `SolaraCoreHost.run` → `ChromeMain`. The main thread is AppKit's event loop, which is also **Chrome's UI thread**: `NSApp` is Chrome's `BrowserCrApplication`, and the RN host (`AppDelegate`, an `ExpoAppDelegate`) starts inside Chrome's run loop. RN mounts views here, along with every `SolaraCoreWebView` and `SolaraCoreWindow`, Chrome's bubbles and menus, every Expo function marked `runOnQueue(.main)`, every engine callback, and `WindowManager` (`packages/shell/ios/Windows.swift`). |
| Browser process, JS thread | Hermes: the zustand store (`useBrowser`), React reconciliation, every store listener, the omnibox's suggestion work (`@solara/core`), persistence serialization (`JSON.stringify` of the whole session), the sync merge, and Live Folders. |
| Browser process, RN shadow queue | Yoga layout (legacy architecture). |
| Browser process, `solara.documents` queue | `DocumentStore` file writes (`ShellModule.swift:115`). |
| Browser process, Chrome's IO thread and thread pool | Chrome's own work: history, passwords, network. |
| Renderer, GPU and utility processes | Chrome's. |

A click on a sidebar row today makes this round trip:

```
main (AppKit event)
  → JS (touch handler → store action → listeners → React commit)
  → shadow queue (Yoga)
  → main (UIManager mount → AppKit layout → Core Animation commit)
```

Each hop waits on the other thread's queue. A busy Chrome task on main delays the mount, and a busy JS thread
delays the response. Engine events take the reverse path: main (delegate) → `emit` → JS (`lib/nativeEvents.ts` holds
page reports for one batch) → store → React → mount.

### 1.2 Who owns which state

| State | Owner today | Persisted where |
|---|---|---|
| Workspace: profiles, windows, tabs, groups, splits, pins, tile folders, parked pins, closed and cleaned items, `pinChoices`, `pinSync` | JS store (`store/*.ts`, 114 actions) | `session.json` (v2) |
| Settings (about 60 typed keys, plus `chosen`, `inferred` and `migrations`) | JS store (`store/settings.ts`) | `session.json` → `settings` |
| Downloads list | JS store (`store/ui.ts`) | `downloads.json` |
| Live tab facts (which tabs each Chrome strip holds, their order, the active tab, Chrome's groups) | Chrome's `TabStripModel`, mirrored into JS (`lib/chromeTabs.ts`, `store/liveTabs.ts`) | Chrome's session |
| Live page state (loading, progress, back/forward, audio, theme color) | JS store `live` | not saved |
| History, bookmarks, favicons, passwords, autofill, extensions, site settings, zoom, cookies | **Chrome** (`Chromium/` in the data folder), reached through `ac_*` calls and `SolaraCoreServices` | Chrome's profile. JS keeps views of them (`history[profileId]`, `bookmarks`), plus `bookmarks-cache.json` for display only. |
| Sync | JS (`sync/engine.ts`, `adapters.ts`, `packages/sync/src` merge). Crypto, vault and keychain are Swift (`SolaraLegacySyncCore`). | `sync.json`, `sync-state.nns`, `sync-journal.nns`, the Keychain service `Solara Sync Key` |
| Live Folders and Calendar | JS (`live/`) | `live.json` |
| Small documents | JS | `onboarding.json`, `release-notes.json`, `solara-cli.json`, `launch-look.json`, `default-browser-offer.json`, `bangs-state.json`, `sync-extensions.json` and kill-switch caches |
| Launch picture | Native (`SolaraCoreEarlyWindow.mm`) | `launch-layout.json`, `launch-picture-*.png` |

The owner's live data folder (`~/Library/Application Support/com.hill.solara`) holds only `session.json` (21 KB),
`launch-layout.json`, `onboarding.json`, `release-notes.json`, `bookmarks-cache.json`, `solara-cli.json` and
`Chromium/`. Sync and Live Folders are off. The plan doesn't rely on that.

### 1.3 How state reaches native views and the engine

- **Windows.** JS calls `openWindow(id, …)`. `WindowManager.open` makes an `SolaraCoreWindow` (`ChromeWindows.makeWindow`)
  and embeds an RN root view for that id (`WindowHost.makeContentView` → `superView(withModuleName: "main",
  initialProperties: ["windowId": id])`). Every window, Settings and Import included, is an RN root on **one** JS
  runtime.
- **Tabs.** Each tab's page is an `SolaraCoreWebView`. That is a plain `NSView` with a delegate
  (`SolaraCoreWebView.h`), created by RN's `WebView` component (`packages/solaracore/src/WebView.tsx`) and driven by
  props (`profile`, `initialURL`, `adoptId`, `transferKey`, `visible`, `frozen`, …). This matters for the move: native
  code can host it with no RN involved.
- **Chrome's tab strips.** The contract is in `docs/store-api.md` › "Live tabs". JS sends `activate`, `arrange` and
  `group` commands (`sendTabStripCommand`). Chrome answers with ordered transactions `{rev, cmd, strips}`, and
  `chromeChanged` folds Chrome's own changes (extensions, Chrome's successor pick) into the workspace. There is one
  writer per fact.
- **Services.** JS → Expo module (`CefModule.swift` and friends) → `SolaraCoreServices` (Obj-C, typed) or
  `SolaraCoreEngineBridge` (`ac_*` C calls in `engine/chromium`, JSON in and JSON out, found through dlsym). Events
  come back through `SolaraCoreEngineBridge.observe` and the event switch in `CefModule.swift`.
- **Menus and app state.** `lib/native.ts` (`startNativeSync`) pushes the menu state, appearance and scroll-bar style
  to `Menus.swift` and the other shell modules on a 120 ms debounce.

### 1.4 Persistence and migrations today

- `lib/persist.ts`: `startPersistence` hydrates the store from `loadSession()`. It then watches each document's
  source slices by reference and, 800 ms after a change, serializes the **whole** document on the JS thread. A
  document whose JSON is unchanged isn't written. `writeDocument` hands the string to `DocumentStore`, which writes
  atomically on its own queue, retries with backoff, and flushes on `willTerminate`.
- `session.json` has `version: 2` and the fields `SessionV2` lists (`persist.ts:105`). Private windows, Little Solara
  windows, Peek tabs and private closed items are left out. `navigation` and `adoptId` are dropped, and `pageIn`
  becomes `unloaded`.
- `hydrate` (`store/browser.ts`) repairs as it loads:
  - drops tabs whose window or profile is gone;
  - `pinnedFirst` reorders each window;
  - keeps `pinnedAsRow` and `tileFolder` only where they're valid;
  - fills `pinnedUrl`;
  - repairs `activeTabIds`;
  - drops empty groups;
  - `sanitizeSplits`;
  - filters the per-profile tables;
  - replays activation in focus order.
- `restoreSession === false` (`loadSession`) parks every window's pins and turns its windows into closed windows.
- **Settings migrations** are named and idempotent. `migrateSavedSettings` runs `withoutBatterySaver`,
  `keepToolbarOnScroll` (recorded in `settings.migrations`) and `withNewTabButtonPosition`. `chosen` and `inferred`
  record which keys the user set.
- **Native readers of `session.json`:** `SolaraCoreHost.mm:158` reads it before JS runs, for the early window
  (`SolaraCoreEarlyWindow prefetchForSession`: `launchTab`, `launchBackdrop`, `linkProfile`).

### 1.5 Sizes

Lines of code, from `wc -l` on 2026-10-26.

| Area | Source | Tests |
|---|---|---|
| `apps/browser/src/store` | 7,564 | 7,511 |
| `apps/browser/src/lib` | 7,678 | 3,673 |
| `apps/browser/src/sync` | 2,941 | 4,749 |
| `apps/browser/src/live` | 1,994 | 244 |
| `apps/browser/src/components` | 42,384 | 2,017 |
| ↳ sidebar / layout / settings / onboarding / site / extensions / media / import / omnibox / pages | 6,906 / 5,695 / 6,337 / 5,074 / 2,744 / 1,594 / 1,610 / 1,548 / 1,356 / 1,312 | |
| `packages/core` (omnibox): logic, plus `bangList.ts` data | about 3,000 + 10,706 | 1,079 |
| `packages/sync/src` (merge, TS) | 1,821 | |
| Native Swift / Obj-C++: `packages/shell/ios`, `packages/solaracore/ios`, `packages/sync/ios`, `packages/import/ios` | 9,894 / 18,804 / about 2,300 / about 5,100 | Swift tests in sync and import |
| Engine: `engine/chromium` (`ac_*`), `engine/solaracore` (`//solara/core`) | 10,889 / 17,042 | |

About 70k lines of TypeScript go away by the end. About 37k lines of native app code and 28k lines of engine code stay.

### 1.6 Costs the owner has seen

**The main thread is shared with Chrome, and RN adds hops to it.**
- 746664cf measured 1.3–1.7 ms of main thread per window move just to report the frame to JS and UserDefaults.
- be42c43a: the hand-driven drag loop "stutters on a fast drag because that thread is Chrome's and React Native's
  too".
- Going native does **not** give the main thread back: it stays Chrome's UI thread. What native removes is the JS
  hop, the shadow-queue hop, serialization across the bridge, React's reconcile work, and RN's mount queue.
  react-native-macos also carries 10 patches of our own.

**The JS-driven window drag.**
- Drag start is 50–83 ms late, after 7–10 pt of travel (3d689889). This is **not** RN's doing: Chromium's
  `BridgedContentView` claims its whole bounds as opaque for window moves (crbug 830962), so every drag waits for
  `mouseDown` on main.
- On macOS 27.2, `performWindowDragWithEvent:` is broken. Solara's fallback moves the window from the main thread one
  event at a time (17ca55fe). It trailed by up to 57 pt until 746664cf, and it now installs only from 27.2 on
  (be42c43a).
- Native views make the fix simpler (the `ServerWindowDrag` approach behind `SOLARA_SERVER_WINDOW_DRAG`, with
  geometry we own instead of walking RN's z-order), but going native doesn't make that work unnecessary.

**Launch.**
- On the 200-tab seed, the window shows its content at 1,070 ms against 490 ms for one tab, and "nearly all of the
  difference is in JS" (`docs/perf/sprint-baseline.md`).
- On a warm one-tab launch, 79% of the time is native start → JS running (387 ms).

**Per interaction.**
- Tab switch (J3) takes 27 ms, 10 ms of it JS. An omnibox keystroke (J2) costs 6.2 ms.
- The ratchet's `switchTabs` scenario wakes 950 store-listener calls over 12 switches. These are counts of the
  RN-era overhead, not of the browser's work.

**Development cost.** Every instance runs everyone's JS through Metro, so there is a "Native API skew" check. An
import-cycle LogBox crashes RN. Shadows crash, and `RCTView` resets layer properties. Expo prebuild and pods sit
between Swift and the app.

---

## 2. The target architecture

### 2.1 Module layout

There is one Swift package, `native/SolaraKit/Package.swift`, plus the app target. The core targets import neither
AppKit nor SolaraCore, so a future WebKit-based iPhone or iPad app can reuse them.

```
SolaraModel        value types, ids, invariants                      (Foundation)
  └─ SolaraStore       commands, reducers, settle passes, commits, rev log
       ├─ SolaraPersistence  GRDB schema, migrator, writer, session.json v2 import/export   (+ GRDB)
       ├─ SolaraOmnibox      packages/core port: parse, fix-up, suggest, bangs, calculator, IDN
       ├─ SolaraSync         SolaraLegacySyncCore (moved as-is) + the merge (port of packages/sync/src) + adapters
       ├─ SolaraImport       packages/import/ios/Core (already plain Swift with a Package.swift), moved
       ├─ SolaraBridgeCore   the bridge's logic in plain Swift (snapshot, dispatch, catch-up, foreign commits), tested without Expo
SolaraSignposts      the fixed perf endpoints and counters of docs/native/baseline.md (Foundation + os)
SolaraEngine (macOS)  typed Swift over SolaraCoreEngineBridge, SolaraCoreServices, SolaraCoreTabStrip,
                      SolaraCoreWebView, SolaraCoreHost; EngineClient, TabViewPool, LiveTabs
SolaraUI (macOS)      AppKit + SwiftUI surfaces: SettingsUI, OnboardingUI, NewTabUI, ToolbarUI, SidebarUI, WindowShell
SolaraRNBridge        Expo module over SolaraBridgeCore exposing the store to JS (deleted in phase 6)
App target            main.swift, AppDelegate (Chrome-hosted), menus (Menus.swift moves here)
```

All targets build for macOS 26 and iOS 26, the owner's minimum.

| Target | Depends on | Platforms |
|---|---|---|
| SolaraModel | — | macOS 26+, iOS 26+ |
| SolaraStore | Model | macOS, iOS |
| SolaraPersistence | Model, Store, GRDB (exact version pinned) | macOS, iOS |
| SolaraOmnibox | Model | macOS, iOS |
| SolaraSync | Model, Store, Persistence | macOS, iOS |
| SolaraImport | Model | macOS (it reads other Mac browsers) |
| SolaraBridgeCore | Model, Store, Persistence | macOS, iOS |
| SolaraSignposts | — | macOS, iOS |
| SolaraEngine | Store, Omnibox; SolaraCore headers (pod until phase 6) | macOS |
| SolaraUI | Model for now; Engine, Store, Omnibox, Sync, Import and `SolaraShaders` as its surfaces need them | macOS |

Reasons:
- `SolaraStore` doesn't import `SolaraOmnibox`. The few reducers that parse URLs (`navigate`'s same-page check,
  `typedNavigationEngine`, `resolveInput` for new tabs) go through an injected `WebAddressing`. The app injects
  Omnibox's `WhatwgURL` and `resolveInput`; tests and the golden replay inject the URL results JS recorded.
- `SolaraBridgeCore` holds everything the Expo module does except the Expo glue, so the bridge's ordering and
  catch-up rules are unit-tested in the package.
- `SolaraEngine` is the only place that knows Chrome. On iOS a WebKit engine target can implement the same command
  and event types. The app already runs a second page engine per tab (`tab.engine`, `WebKitTab.swift`), so the
  boundary has a real second user.
- The Expo wrappers (`CefModule.swift`, `ShellModule.swift`, `SyncModule.swift`) are thin. Their logic moves into
  plain Swift types the UI calls directly, and the modules shrink to adapters until phase 6 deletes them.

**Where Rust could come in later, in isolation.** None of these is needed for macOS or iOS, since Swift covers both.

| Candidate | Why it would fit | When |
|---|---|---|
| Omnibox scoring, fuzzy matching, bang table | Pure functions with a frozen reference spec and property tests (`suggest.reference.ts`) | Only for a non-Apple platform |
| Sync merge and file format | Pure, security-sensitive, wire format fixed by `docs/sync.md` | Only if a non-Apple client must sync |
| Importer parsers for other browsers' databases | Untrusted input, fuzzing-friendly | If fuzzing finds Swift parser crashes we can't contain |

### 2.2 The core's data model

The model keeps the JS store's shapes and **string ids verbatim**. Sync record keys are built from them (`pin:t:<id>`,
`bm:<id>`), `newId` has a random part so ids are unique across Macs, and the golden replay (§5.2) diffs states
directly.

```swift
public struct BrowserState: Sendable, Equatable {
  public var profiles: [Profile.ID: Profile]
  public var profileOrder: [Profile.ID]
  public var windows: [Window.ID: BrowserWindow]
  public var windowOrder: [Window.ID]
  public var tabs: [Tab.ID: Tab]
  public var groups: [TabGroup.ID: TabGroup]
  public var splits: [SplitView.ID: SplitView]
  public var parkedPins: [Profile.ID: ParkedPins]
  public var pinChoices: [Profile.ID: PinTable]
  public var pinSync: [Profile.ID: PinTable]
  public var closedTabs: [ClosedTab]
  public var closedWindows: [ClosedWindow]
  public var closedGroups: [ClosedGroup]
  public var deletedGroups: [ClosedGroup]
  public var cleanedTabs: [CleanedTab]
  public var orphanedProfileData: [String]
  public var downloads: [Download]
  public var settings: Settings
  public var focus: FocusState
  public var session: SessionState
}
```

| Entity | Fields (as in `store/types.ts`) | Notes |
|---|---|---|
| `Profile` (Dia's profiles; Arc spaces import as profiles) | `id, name, color, icon, createdAt, dataId?, theme?` | `dataId` shares one engine profile's data. `engineProfile(id)` resolves it. |
| `BrowserWindow` | `id, profileId, incognito, tabIds, activeTabIds[profile], sidebarOpen, tabLayout?, frame, fullScreen?, createdAt, kind? ("small"), linkPointer?, originalProfileId?` | `tabIds` is the sidebar order. A private window's profile id is `incognito:<window>@<profile>`. |
| `Tab` | `id, windowId, profileId, url, title, favicon, pinned, pinnedAsRow?, tileFolder?, pinnedUrl, pinKey?, muted, zoom, customTitle, customIcon, openerId, wakeAdoptId?, liveItem?, unloaded?, engine?, createdAt, lastActiveAt` | `navigation`, `adoptId` and `pageIn` are session-only (`SessionState`). |
| `TabGroup` | `id, windowId, profileId, name, icon, color, collapsed, pinned, tabIds, createdAt, autoUngroup?, pinnedOpenerId?, pinKey?, parentId?` | Groups nest through `parentId`. |
| `SplitView` | `id, windowId, tabIds (2–3), orientation, sizes, stack?` | One sidebar row. |
| Pinned rows, tiles and folders | Not separate entities: a tile is a pinned tab, a pinned row is `pinnedAsRow`, a folder is `tileFolder` | As today. A Live Folder's place in the pinned order lives in Live state (`after` anchor). |
| `Settings` | Typed struct with every key in `store/settings.ts`, plus `chosen`, `inferred` and `migrations` | Keys a newer build wrote survive (§2.5). |
| History pointers | None in the core | History is Chrome's. The omnibox keeps its own index (§2.6). `closedTabs` and friends carry `tabId`/`restoreFrom`, so Chrome can restore the back/forward list. |
| Live tab state | Not in the core | `LiveTabs` (main actor, per tab) is fed by the engine directly: loading, progress, back/forward, audio, theme color, find, permissions. |

**Invariants.** `SolaraModel.check(state)` asserts all of these. It runs after every commit in Debug builds and in
tests, and on import.
1. A window's `tabIds` lists exactly the tabs whose `windowId` is that window, in sidebar order, pinned first: tiles,
   then pinned rows and pinned groups interleaved, then the rest (`pinnedFirst`).
2. A group's members are contiguous in its window's order and share its pinned state. Nested groups sit inside their
   parent. No group is empty.
3. A split has 2–3 panes, contiguous, all pinned or all unpinned, and moves as one row.
4. `activeTabIds[p]` is a tab of that window with profile `p`, and the shown profile always has one.
5. Pins are per profile. Each regular window showing a profile holds a copy of every pinned tile and pinned group,
   linked by `pinKey`. A profile's `parkedPins` is non-empty only while no window shows it.
6. `tileFolder` appears only on pinned tiles, members sit next to each other, and a one-member folder dissolves.
7. `pinnedUrl` is set exactly when a tab is in a pinned place (`settlePinHomes`).
8. Private windows, Little Solara windows and Peek tabs are never persisted. Private closed items never leave memory.
9. Ids are unique across all entity kinds and never reused.

### 2.3 Commands, transactions and the settle pipeline

- **Commands map 1:1 to today's store actions** (`newTab`, `closeTabs`, `activate`, `placeTabs`, `dropTabs`,
  `pinTabs`, `createGroup`, `createSplit`, `switchProfile`, `updateSettings`, …; 114 in all), with the same
  arguments. JS call sites therefore don't change in phase 1, and the golden replay can drive both implementations
  from one script. A caller that needs a new id passes it in, or gets it back in the commit.
- **A reducer is a pure function:** `(inout BrowserState, Command) throws -> [Effect]`.
- **Settling happens inside the transaction.** Today, invariants are restored after the fact by `subscribe` listeners
  that call `setState` again. That makes them hidden writers. The core runs them inside the transaction, in the order
  `browser.ts` registers them, before anything is published:
  1. `forgetClosedPrivateWindows`
  2. `settleNesting`
  3. `livePinTable` (`pinChoices`, `pinSync`)
  4. `settlePeeks`
  5. the mirror chain: `settlePinHomes` → `unshareTabs` / `pagesIntoSplits` → `settleSharedPins` →
     `settleTileFolders` → `mirrorPins` → `mirrorTabs`, repeated to a fixpoint with the same cap of 4 passes
     (`mirroring > 3`).

  A command is one transaction. `dispatch([Command])` batches several into one, as `storeTransaction` does for the
  engine's held page reports (`lib/nativeEvents.ts`).
- **A commit** is `{rev, changes: ChangeSet, effects}`. `rev` increases by one per commit for the process's lifetime.
  `ChangeSet` lists, per entity table, the ids upserted and removed, plus the settings keys and singletons changed.
- **Effects** are what the store asks the outside world to do, executed after the lock is released:
  - `stripCommand`, `loadURL`, `discard`, `releaseProfile`;
  - `openWindow`, `closeWindow`;
  - `deleteProfileData`;
  - `bookmarkOps`;
  - `notify`.

  Reducers never call the engine.

### 2.4 Threading

| Actor or queue | Runs |
|---|---|
| `@MainActor` | All AppKit and SwiftUI. Every engine call and callback, since Chrome requires its UI thread. `EngineClient`, `TabViewPool`, `LiveTabs`, and the observable projections (§2.5). Effect execution. |
| `Store` (nonisolated, `final class Store: Sendable`, state behind `OSAllocatedUnfairLock`) | `dispatch` from any thread. In phase 1 that includes the JS thread, synchronously (§4). Reducers plus settling typically take tens of µs; the budget is 1 ms on the 200-tab seed. |
| Persistence writer (a GRDB `DatabasePool` writer, background QoS) | Coalesced row writes and the `session.json` shadow export. |
| `SuggestionEngine` actor | Omnibox: index maintenance, parsing, ranking. |
| Sync actor | The cycle, merge, file IO (already off main in `SyncVault`), compaction. |
| Importers (`Task.detached`) | Reading other browsers' data. |

Why a lock rather than `@MainActor` for the store:
- During the bridge phase, JS must read its own writes synchronously. `const id = newTab(…)` followed by reads of the
  new state is common across 29 `useBrowser.setState` sites and the 114 actions.
- A synchronous hop from the JS thread to main (`DispatchQueue.main.sync`) would stall on Chrome's tasks and risks
  deadlock.
- An uncontended unfair lock costs about 20 ns. After phase 6 every caller is on main and the lock is never contended,
  so it stays.

A commit that originates on main (an engine event, a native control) updates the projections **synchronously in the
same run-loop turn**. A click goes: AppKit event → `dispatch` → projections → view update → Core Animation commit,
with no thread hop. Commits from other threads (JS in phase 1, sync) reach main with one `DispatchQueue.main.async`.

Main-thread rule: no JSON, no SQLite, no suggestion ranking, and no full-state diffing on main. A row's model
updates in O(1). A window's derived row list (the port of `sidebarEntries`) is recomputed only for dirty windows,
O(n) in that window's tabs, which `micro-bench` already holds to well under 1 ms at 1,000 tabs.

### 2.5 How SwiftUI and AppKit observe the core

Projections are `@Observable @MainActor` classes the UI binds to. They are kept in step from each commit's
`ChangeSet`, so only the objects whose entities changed are touched:
- `AppModel`: profiles, window order, focus, `SettingsModel`.
- `WindowModel`: profile, layout, sidebar open, active tab, `rows: [RowID]` (pinned tiles, pinned rows and groups,
  Live Folders, the rest, splits as one row).
- `TabModel` per tab: persisted fields. `LiveTabModel` is separate and fed by the engine, so a progress tick never
  touches the store.
- `GroupModel`, `SplitModel`.

How each kind of UI reads them:
- **SwiftUI** (Settings, onboarding, New Tab) reads the projections directly. A setting is a `Binding` built by
  `SettingsModel.binding(\.warnBeforeQuitting)`, which dispatches `updateSettings`, so `chosen` is maintained the same
  way it is today.
- **AppKit** (sidebar, toolbar, tab rows) uses a small `observe { }` helper over `withObservationTracking` that
  re-arms after each change and coalesces to one `needsLayout` / `needsDisplay` per run-loop turn. A row observes its
  own `TabModel`, so a title change re-lays out one row. This is the native counterpart of today's narrow zustand
  selectors. (Newer AppKit may track Observation in layout by itself. That is from memory and unverified here; check
  it before it weighs on §7's deployment-target question.)

### 2.6 Engine events in, commands out

```
Chrome (UI thread = main)
  SolaraCoreWebView delegate ─┐            ┌─▶ LiveTabs (not stored)
  SolaraCoreTabStrip txns ────┼─▶ EngineClient ─┤
  EngineBridge topics ───────┤            └─▶ Store.dispatch(.engine(…)) ─▶ Commit ─▶ projections
  SolaraCoreServices handlers ┘                                               └▶ effects ─▶ EngineClient ─▶ Chrome
```

- **`EngineClient`** (main actor) gives the C and Obj-C surface typed async Swift. `ac_*` calls become `Codable`
  request/response pairs over `SolaraCoreEngineBridge.call`, guarded by `exports:`. `SolaraCoreServices` callbacks
  become `async` functions. Topic events (`history.changed`, `tabs.strip`, bookmarks, extensions, downloads) become
  `AsyncStream`s.
- **`TabViewPool`** owns one `SolaraCoreWebView` per loaded tab, keyed by tab id (`transferKey`). It is the delegate
  in place of the RN view module, and it sets `visible`, `warm`, `frozen` and the rest from the window's projection.
- **The tab-strip contract stays exactly as `docs/store-api.md` defines it.** `chromeChanged` (a port of
  `store/liveTabs.ts`) is a reducer. `stripPlan` and the "one command per strip at a time, never resend unchanged"
  rule (a port of `lib/chromeTabs.ts`) live in `EngineClient` and run after each commit. The fake-engine tests in
  `liveTabs.test.mjs` become golden-replay cases (§5.2).
- **Event order across sources.** Strip transactions and WebView events (`onOpenWindow` with a `tab:` adoption,
  navigation) must be applied in the order Chrome emitted them, which `lib/nativeEvents.ts` keeps today. While WebView
  events still reach the store through JS (phases 1b–4), strip transactions do too: JS forwards each one as a
  `stripTransaction` command, and Swift's `chromeChanged` and `stripPlan` run on it. Only in phase 5, when
  `TabViewPool` is the WebView delegate, does `EngineClient` subscribe to `SolaraCoreTabStrip` directly, so both
  sources arrive on main in emission order.
- **Omnibox.**
  - `SuggestionEngine` (actor) keeps an in-memory index built from `ac_history_query` plus `history.changed`,
    `ac_bookmarks_tree`, open tabs (from commits), search engines (settings plus `ac_search_engines`), and the bang
    table, generated at build time from `bangList.ts` into a resource.
  - Each keystroke carries a generation number. Main applies only the newest result.
  - Remote suggestions use the same endpoints as `suggestFetcher.ts`.
  - The core drops `history[profileId]`, the whole-history mirror the JS store keeps in memory today.

### 2.7 Persistence: GRDB

The database is one file, `solara.sqlite`, in the data folder (`SOLARA_DATA_DIR` is honored), opened as a GRDB
`DatabasePool` in WAL mode with `synchronous = NORMAL`, `fullfsync = ON`, `checkpoint_fullfsync = ON` and
`foreign_keys = ON`. Durable writes temporarily use `synchronous = FULL` and finish with a FULL WAL checkpoint.
Ordinary writes stay at NORMAL; a power loss can lose uncheckpointed commits while preserving consistency.
Writes are off main and debounced; marking a commit durable queues its flush immediately.

```sql
CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT NOT NULL);
CREATE TABLE setting (key TEXT PRIMARY KEY, position INTEGER NOT NULL, value TEXT NOT NULL);
CREATE TABLE download (id TEXT NOT NULL, position INTEGER PRIMARY KEY, payload TEXT NOT NULL);
CREATE TABLE document (name TEXT PRIMARY KEY, value TEXT NOT NULL);
CREATE TABLE profile (id TEXT PRIMARY KEY, seq INTEGER NOT NULL, payload TEXT NOT NULL);
CREATE TABLE "window" (id TEXT PRIMARY KEY, seq INTEGER NOT NULL, profile_id TEXT NOT NULL, payload TEXT NOT NULL);
CREATE TABLE tab (id TEXT PRIMARY KEY, seq INTEGER NOT NULL,
  window_id TEXT NOT NULL REFERENCES "window"(id) ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED,
  profile_id TEXT NOT NULL, position INTEGER NOT NULL, payload TEXT NOT NULL);
CREATE INDEX tab_by_window ON tab (window_id, position);
CREATE TABLE tab_group (id TEXT PRIMARY KEY, seq INTEGER NOT NULL,
  window_id TEXT NOT NULL REFERENCES "window"(id) ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED, payload TEXT NOT NULL);
CREATE TABLE split (id TEXT PRIMARY KEY, seq INTEGER NOT NULL,
  window_id TEXT NOT NULL REFERENCES "window"(id) ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED, payload TEXT NOT NULL);
CREATE TABLE pin_table (kind TEXT NOT NULL, profile_id TEXT NOT NULL, seq INTEGER NOT NULL, payload TEXT NOT NULL,
  PRIMARY KEY (kind, profile_id));
CREATE TABLE archive (kind TEXT NOT NULL, position INTEGER NOT NULL, id TEXT NOT NULL, closed_at REAL NOT NULL,
  payload TEXT NOT NULL, PRIMARY KEY (kind, position));
CREATE TABLE workspace (key TEXT PRIMARY KEY, value TEXT NOT NULL);
```

**As built: payload rows with key columns.** The first draft of this section gave every tab and window field a
column. The build instead stores each entity as one row holding its `session.json` JSON (`payload`), plus the
columns the database itself needs: the id, `seq` (the order the file had), the foreign keys with their cascades, and
`position` for the tab index. Reasons:
- The import is lossless by construction. Unknown fields, absent-versus-null keys, numbers and a value this build
  can't read survive the round trip byte for byte, which the oracle checks through the database (§3.3).
- The shadow export and the import are copies, not translations, so the oracle has one code path to cover.
- A write still touches only the changed rows: the writer diffs rows by payload, and a move only rewrites `seq`.
- Columns for querying (`url`, `title`) can be added by a migration when a query needs them.

`setting` is one row per key, in the order the settings object had. `chosen` and `inferred` stay keys inside the
settings, as `settings.ts` keeps them, rather than columns.

**Unreadable rows.** A row whose payload doesn't parse, or a nested value of the wrong shape, costs only itself. A
nested value Swift can't decode (a string where an object belongs) is kept exactly as written and exported again
unchanged. An entity that isn't an object at all is dropped from the loaded state but its row stays in the database
untouched. An unreadable setting or download row is skipped. Each case is listed in `import.log`. A load error SQLite
itself raises is handled like corruption: the file moves aside and the importer runs on the shadow (§3.4).

**Archives and documents.**
- Closed, cleaned and deleted items (`archive.kind`), parked pins and pin tables are written rarely and read as
  wholes, so an archive kind is rewritten whole when it changes.
- `document` takes the small JSON documents (onboarding, Live state, CLI) as their owners port.

**Write strategy.**
- Each commit's `ChangeSet` is merged into a dirty set.
- The writer flushes it in **one transaction** 250 ms after the first change, or at once for commits marked durable:
  closing a window, deleting a profile, settings, quit. A flush upserts only the dirty rows. Durable commits write
  the shadow in the same flush; ordinary commits export it after two seconds.
- When a window's order changes, that window's `position` values are rewritten. That is at most a few hundred rows,
  about 1–2 ms off main.
- Today's equivalent re-serializes the whole session on the JS thread every 800 ms after any change.

**Crash safety.**
- WAL plus a single transaction per flush: a crash loses at most the last 250 ms, never half a flush. Today the loss
  window is 800 ms.
- `willTerminate` flushes synchronously with a 500 ms deadline (`DocumentStore`'s pattern): the rows first, then the
  shadow `session.json` (§3.4), so the next launch's early window shows the right tab. The durable row flush runs
  `PRAGMA wal_checkpoint(FULL)` even when no row changed. The result distinguishes saved, failed and timed out;
  quit logs a failure or timeout and proceeds.
- At launch, `PRAGMA quick_check` runs (sub-ms at this size). If it fails, the file moves to
  `solara.sqlite.corrupt-<date>` and the app re-imports from the shadow `session.json` (§3.4).
- Moving a database aside moves its `-wal` and `-shm` first, then the main file, so a crash in between can never
  leave an old WAL next to a new database. An import that finds a `-wal` or `-shm` with no `solara.sqlite` moves
  them aside (`.orphan-<date>`) before it renames the new file into place; SQLite would otherwise replay the old
  WAL into it.
- A failed flush or shadow write retries after 1 s, 5 s, then every 30 s. After three failures in a row the writer
  reports the error through its `trouble` callback, which the app logs and surfaces; only the last 20 errors are
  kept.

**Versioning.** A GRDB `DatabaseMigrator` applies named, forward-only migrations, and `meta.schema` records them. A
build that finds migrations it doesn't know (a downgrade) doesn't open the database: it falls back to the shadow
`session.json`.

**Forward compatibility.** `setting` rows for keys this build doesn't know are kept and written back unchanged, as
today's `{...DEFAULT_SETTINGS, ...saved}` keeps them. Unknown JSON fields in `archive` payloads survive the same way.

---

## 3. Migrating the owner's data

### 3.1 What moves, what doesn't

| Data | Action |
|---|---|
| `session.json` v2 (profiles, settings, windows, tabs, groups, splits, closed / cleaned / deleted items, parked pins, `pinChoices`, `pinSync`, focus, last profile) | Imported into `solara.sqlite` once, in phase 1b, when Swift owns everything in the file. |
| `downloads.json` | Imported (`download`). |
| `sync.json`, `sync-state.nns`, `sync-journal.nns`, Keychain `Solara Sync Key` | **Untouched.** The sync engine keeps reading them in every phase. Only the record source changes (§4.5). |
| `live.json` | Imported into `document` when Live Folders port (phase 2). |
| `onboarding.json`, `solara-cli.json`, `default-browser-offer.json`, `bangs-state.json`, `sync-extensions.json`, `release-notes.json` | Imported into `document` when their owner ports. |
| `launch-layout.json`, `launch-picture-*.png`, `bookmarks-cache.json`, `switches-cache.json` | Caches. Not migrated: rebuilt or deleted. |
| `Chromium/` (history, bookmarks, passwords, autofill, extensions, cookies, site settings) | **Chrome's. Never touched.** The engine reads it as it does today. |

### 3.2 The one-time import

- **When.** Phase 1a imports only `settings` (through the port of `migrateSavedSettings`) and `downloads.json`. Phase
  1b imports the rest of `session.json`. In 1a, `persist.ts` (still the writer of `session.json`) adds the same
  `nativeExport` marker as the later shadow export, so the downgrade check in §3.4 works from the first nightly.
- **Where.** `main.swift`, before `SolaraCoreHost.run`. That is before Chrome starts, before any window, and with
  nothing touching `NSApp`. Test it with an executable tool and XCTest fixtures.
- **What.** `SessionV2Importer` is a straight port of `loadSession()` + `migrateSavedSettings` + `hydrate`'s
  repairs (§1.4), including the `restoreSession === false` branch. It produces a `BrowserState`, runs
  `SolaraModel.check`, and writes it to `solara.sqlite.importing`.
- **Atomic.** The import writes the temporary file, syncs it with `F_FULLFSYNC`, then renames it to
  `solara.sqlite` and syncs the folder. A crash mid-import leaves no database, so the next launch imports again.
- **The originals are kept.** Before anything else, the first native launch copies `session.json` and
  `downloads.json` to `session.json.pre-native` and `downloads.json.pre-native` (synced, then renamed into place).
  Those copies are never overwritten or pruned. If `session.json` is ever missing, the importer reads the
  `.pre-native` copy instead. The source files themselves are left alone until the first change the user makes
  (§3.4).
- **Per entity, and refused when it would lose much.** Each profile, window, tab, group, split and archive entry is
  decoded on its own. A bad one is dropped and listed in `import.log`, never the whole file. The import is refused,
  and the app runs on the JS store and `session.json` as today, when `session.json` exists but can't be parsed or
  has another version, or when fewer than half of the profiles, windows or tabs it lists are readable at all (the
  JS loader's own repairs, such as dropping tabs whose window is gone, don't count: JS makes them too). A refusal writes nothing but
  `import.log`, so the next launch tries again.
- **Recorded.** `meta` holds `imported_from = session.json`, its version, the SHA-256 and size of the source, the
  app version, the import time, and the counts per entity before and after repair.
- **Checked.** Counts are logged. Anything repair dropped is listed in `import.log` in the data folder, so a
  surprising loss is visible instead of silent.

### 3.3 Proving it loses nothing

The oracle is the JS loader itself. A Node script (`apps/browser/scripts/native/session-oracle.mjs`) runs
`loadSession()` + `hydrate()` on a `session.json` and prints the hydrated persisted slices as canonical JSON. The
Swift importer, run through its CLI on the same file, prints the same canonical form. They must be **byte-identical**.
- The fixtures are the existing test sessions, the `persist` and `settingsMigrations` cases, synthetic edge cases
  (`restoreSession: false`, orphaned tabs, a broken split, a deleted profile), and big seeds from
  `apps/browser/scripts/perf/seed.mjs`.
- The owner's real `session.json` is copied into a scratch dir (never committed) and run through both before the
  phase ships.
- `oracle-check.mjs` compares each folder twice: straight from the files, and through a scratch `solara.sqlite`
  (`--via-db`: import, write the rows, load them back). Both sides print the document's own text next to the
  canonical form, so key order is compared too, and `memoryAfter` (the id counter after loading). Swift goes through
  `Importer.read`, the path the app uses. No folders at all is a failure, not "0 of 0 identical".
- `session-fixtures.mjs` writes a wrong-shape fixture for every nested value the importer decodes (a string where a
  tile folder, navigation, split stack, closed-tab snapshot or group head belongs, a number in a list of tabs, a
  null window), plus a missing `session.json` and an unparseable one.
- Two differences are expected and declared in the fixture's `oracle.json`. A null closed tab makes `persist.ts`
  throw, so JS can't load the file; Swift drops that entry and loads the rest. And a Swift `String` can't hold a
  lone UTF-16 surrogate (`"\ud83d"`), so the importer writes U+FFFD where JS keeps it; the oracle compares that
  fixture after the same replacement. Only text the page supplied, such as a title cut mid-emoji, can contain one.
- In the app, the first launch after the import compares the importer's counts with what JS hydrates from the
  bridge snapshot, and logs any difference.

### 3.4 Versioning and rollback

- **Shadow export.** The persistence writer keeps writing a v2 `session.json` (debounced 2 s, off main), exactly
  what `persist.ts` writes today, plus one extra key, `"nativeExport": {"rev": …, "at": …}`. Each write goes to a
  temporary file, is synced with `F_FULLFSYNC`, and is renamed into place. Nothing is written until the state
  changes, so a launch that changes nothing leaves the user's files as they were. It includes `launchTab` and
  `linkProfile`, ported with the exporter (`store/launchTab.ts`). `launchBackdrop` is computed in Swift
  (`SolaraStore/LaunchBackdrop.swift`, a port of `lib/launchBackdrop.ts` checked against cases recorded from it) for
  the focused public window at export time. It does this from the import until phase 6 ships plus two stable releases. That
  keeps two things working:
  1. `SolaraCoreHost.mm`'s early-window read (`launchTab`, `launchBackdrop`, `linkProfile`), unchanged until the
     window shell goes native;
  2. **rollback**: installing an older build (or one from the other channel) finds a current `session.json` and runs
     on it as today.
- **Downgrade, then upgrade.** An older (JS-store) build ignores unknown keys and drops `nativeExport` when it
  rewrites the file. So at launch, a `session.json` **without** the marker means an older build wrote it since our
  last export. The database moves aside (`solara.sqlite.superseded-<date>`) and the importer runs again on
  `session.json`. Newer-only fields kept in `setting` are merged back by key, and every `document` row is carried
over. A marker whose `rev` is
  behind the database's is normal (a crash before the next export) and changes nothing, so an ordinary crash never
  triggers a re-import. This needs no atomicity across the two files.
- **Schema downgrade.** An older build with a newer `solara.sqlite` sees migrations it doesn't know, refuses the
  database, and imports the shadow `session.json`. Nothing is lost, because the shadow is always current.
- **Moved-aside copies.** Each label (`corrupt`, `newer`, `superseded`, `unreadable`, `orphan`) keeps its newest
  three copies; older ones are deleted at launch. The `.pre-native` originals are never pruned.
- **No kill switch.** `SOLARA_NATIVE_STORE` is gone: the store is the only one. When it can't open, the app saves
  nothing that launch and Settings shows why (`StoreUnavailable`).

---

## 4. The transition bridge

### 4.1 One writer

From phase 1 on, **the Swift `Store` is the only writer** of the slices it owns. JS keeps a zustand **replica** of
them for the RN surfaces still in use.

| Phase | Swift owns | JS still owns (not persisted, or not yet ported) |
|---|---|---|
| 1a | settings and downloads (`downloads.json` → `solara.sqlite`) | everything else. `persist.ts` stays the single writer of `session.json`, reading `settings` from the replica. JS still owns profiles and windows, so it sends each download's profile and private-session context with the download command, and it dispatches the `defaultProfileId` repair (pointing the setting at a profile that exists) after hydrating profiles. Both move into Swift with profiles in 1b. |
| 1b | + profiles and the whole workspace (windows, tabs, groups, splits, pins, parked, closed/cleaned/deleted items, pin tables, focus), the `session.json` import and shadow export, and the tab-strip reconciliation (`liveTabs` / `chromeTabs`, fed by JS-forwarded transactions until phase 5) | `live`, `find`, `windowUi`, `selection` / anchors, Peek UI, the history and bookmark views, the sync engine (writing through commands) |

Why profiles wait for 1b: `deleteProfile` and `createProfile({ shareWith })` change windows, tabs, parked pins and
`orphanedProfileData` in one action, so splitting profiles from the workspace would make one action span two writers.
And `session.json` holds settings, profiles and the workspace together, so it has one writer at every step: JS until
1b, Swift (as the shadow export) from 1b on.

### 4.2 The bridge API

`SolaraRNBridge` is an Expo module.

| Call | Thread | Returns |
|---|---|---|
| `snapshot()`, sync | JS | `{rev, data: HydrateData}`, the shape `hydrate` already takes, which replaces `loadSession()`. |
| `dispatch(commandJSON, sinceRev)`, sync | JS, takes the store lock | `{rev, patches}`: **every** patch after `sinceRev`, its own included. |
| event `onStoreCommit {rev, patch}` | delivered on JS | Commits JS didn't originate (engine, sync, native UI). |

Patch JSON is encoded after the store lock is released, from the commit's `ChangeSet` and the state snapshot it
produced, so no thread holds the lock while encoding.

**Ordering and read-your-writes** work like the tab strip's `rev` contract. JS tracks the last `rev` it applied.
`dispatch` returns everything since then, so JS applies in order and sees its own write before `dispatch` returns. An
`onStoreCommit` at or below the applied `rev` is dropped. Swift keeps a ring of the last 1,024 patches; a gap larger
than that returns a full snapshot instead.

**Patches** are entity-level: `{tabs: {upsert: [...], remove: [...]}, windows: …, settings: {...}}`. The JS applier
replaces only the changed entities' objects, so object identity, narrow selectors and render counts behave as they
do today. Acceptance: the ratchet's exact counts (`switchTabs.subNotified`, the renders, `hover`) don't rise.

### 4.3 Removing the hidden writers

All of these become commands, or move into the Swift transaction, in the sub-phase that moves their slice:

| Writer | Becomes |
|---|---|
| `browser.ts` listeners: `forgetClosedPrivateWindows`, `settleNesting`, `livePinTable`, `settlePeeks`, the mirror chain | Settle passes in the Swift transaction (§2.3); deleted from JS |
| `useBrowser.setState` in `sync/adapters.ts`, `sync/pinned.ts` | A `sync.apply(records)` command; Swift keeps the invariants (group contiguity, pinned-first) |
| `lib/chromeTabs.ts` (`chromeChanged`) | Swift's reducer, fed natively; deleted from JS (1b) |
| `lib/history.ts`, `lib/bookmarks.ts`, `lib/bookmarkGroups.ts`, `lib/launchLook.ts` | Their own JS-owned slices stay JS until their surface ports; the bookmark-to-group action becomes a command |
| `components/import/apply.ts`, `onboarding/state.ts`, `littleSolara/actions.ts`, `sidebar/tidyPinsUi.ts`, `sidebar/tileFolderUi.ts`, `store/pinOrderChoices.ts` | Commands |

That covers 29 `setState` sites in 14 files (test fixtures excluded). A Debug-build guard wraps `setState`: writing a Swift-owned key outside
the patch applier throws, with the call site, so a missed writer fails the first test that hits it.

### 4.4 Native ↔ RN hosting

- **RN inside a native window** (Settings during phase 2):
  - The Settings window becomes an AppKit `NSWindow` with an `NSSplitViewController`. The sidebar, search field,
    back/forward and title are native (SwiftUI).
  - A ported pane is an `NSHostingController`.
  - An unported pane is an RN root, `makeContentView("settings-pane")` with `initialProperties {pane, profileId,
    detail}`. A new `SettingsPaneRoot` renders that one pane, on the same JS runtime with no new bridge.
  - Navigation (`useSettingsNav`) becomes native and feeds the pane through props.
  - The search index (`settingsIndex.ts`, 110 rows) moves to Swift as static data, as does the reveal-and-flash. For
    an RN pane, native asks the pane, through a small JS function, for the anchor's y-offset.
  - Sheets (`useSettingsSheet`) render at the RN root today and would be clipped to the pane, so they become native
    `NSWindow` sheets as each one's data ports. Until then the RN pane presents them in an RN root hosted by a
    sheet window.
- **Native inside an RN window** (New Tab in phase 3, toolbar in phase 4):
  - An Expo native view `SolaraHostedView(kind, windowId, tabId)` holds an `NSHostingView` or an AppKit view.
  - RN lays out the hole. The native view reads its projections directly, not through props, so a keystroke or
    progress tick crosses no bridge.
  - Focus between RN and native views goes through AppKit's responder chain. Each hosted kind has a focus test in
    `shortcuts-test.mjs`.
- **Phase 5 flips the window.** The window shell becomes native (sidebar, content card, splits, `TabViewPool`), and
  the RN root of a browser window is removed.

#### Page views: static ownership

Behind `SOLARA_NATIVE_PAGES_POOL` (which needs `SOLARA_NATIVE_SHELL`), `TabViewPool` owns every page view in a
shell-wrapped window from the moment the window exists, and RN mounts no page view there: no card, no warm or
neighbour page, no New Tab prewarm. No page moves between RN and the pool while a window is open. Where RN mounts a
page view today, and what each becomes:

| RN mount today | Becomes |
|---|---|
| ContentCard → TabPane → TabWebView (the active tab) | pool card slot |
| split panes (the same TabPane map) | pool pane slots |
| warm neighbours (pager profiles' active tabs, the drag successor) | pool, waiting behind the card |
| the kept-mounted set and the hidden-pane prewarm | pool, in the window's hidden container |
| New Tab prewarm (`usePrewarm`) | pool hidden tab, or off in shell windows |
| Peek (`PeekOverlay` → `PeekPage`) | pool peek slot |
| Little Solara (`LittleSolaraWindow` mounts its own ContentCard) | stays RN: the one boundary |
| extension popup frame, extension side panel | unchanged: no `transferKey`, so nothing is handed over |

Little Solara is the one boundary. A tab moving between a shell window and a small window crosses it through the
park path: the pool parks its own view's tab synchronously on main (`-parkForCrossing`: mark handing off, detach,
park under the key with a bounded hold, clear the view's `transferKey`) before the store drops it, and the small
window's view takes it from the parking lot. WebKit tabs cross through `WebKitHub` (prepare the key, so `close()`
parks the web view instead of destroying it). A non-shell to shell move needs nothing new.

When a window closes: on a close the app starts, the pool's pages move synchronously into one
keeper window per profile and the pool places them where the store says; on a close Chrome starts (an extension's
`chrome.windows.remove`) nothing is kept, the tabs' closes reach the store, and the store and the live pages agree.
The engine asks which tabs to keep before any beforeunload runs (`window:tabsToKeepOnClose:closedByChrome:`), leaves
those tabs out of the beforeunload and unload passes, and moves exactly that set once the close is committed
(`window:moveKeptTabs:`); a cancelled close moves nothing. A kept tab that fails to move gets its beforeunload then
and closes with the window. A kept page's own `window.close()` while its window waits on another tab's beforeunload
is dropped (Chrome refuses closes in that state) and isn't retried after the move.

### 4.5 Sync during the move

Sync must stay wire-compatible: a Mac on a native build syncs with one still on JS.
- In phases 1–4 the **merge stays in TypeScript** (`packages/sync/src` + `apps/browser/src/sync`), on the replica.
  Its adapters write through `sync.apply` commands.
- In phase 5 the merge and adapters port to `SolaraSync`. Wire compatibility is held by:
  - `packages/sync/src/fixtures` (`scope-v0.2.38.ts`), `sync/fixtures/pinned-v0.2.3x.ts` and the two-device tests in
    `adapters.test.mjs`, run as golden replays;
  - a cross-implementation test: a TS device and a Swift device sharing one folder.

### 4.6 Wiring checklist

Things the code that wires a native module into the app must do. Each one fails silently if it's left out.

| Module | At | Do |
|---|---|---|
| `SolaraOmnibox` | Launch, before the first URL is parsed or shown | Call `setAppScheme(productName)` (or `AppScheme.set(productName:)`) with the product identity, the same name `setAppScheme` gets in JS today. Until then `appUrlOrigin`, `toAppUrl`, `fixupUrl` and `urlForDisplay` use upstream's `solara://`. |
| `SolaraOmnibox` | Remote suggestions, Chrome's engine list | Parse the raw JSON text with `SolaraModel.JSONValue.parse`, which keeps JS key order. A `JSONSerialization` dictionary loses it, and `extensionEnginesFromChrome` keeps the first engine per extension in that order. |
| `SolaraPersistence` | Launch | Call `Launcher.open` in `main.swift` before Chrome starts. If it throws `ImportRefused`, show the saved session read-only and save nothing; if anything else fails, save nothing that launch. Log the reason either way; never start the native store on a partial import. |
| `SolaraPersistence` | The writer | Build `PersistenceWriter` from `Launch.persisted`, never from the store's state, so a launch-time repair committed before the writer exists still reaches the database. Wire its `trouble` callback to the log and an error report. Call `flush` from `willTerminate`. |
| `persist.ts` | Phase 1a | Keep writing `session.json`, with `"nativeExport": {"rev", "at"}` added, and stop writing `downloads.json` (the native writer's shadow does). Without the marker, every launch would take a re-import as if an older build had run. |
| `persist.ts` | Phase 1b | With the native store on, never write `session.json` or `downloads.json`. The shadow export owns both, and a JS write would look like a downgrade and re-import at every launch. |
| `SolaraStore` | Store creation | Inject a `WebAddressing` built on `SolaraOmnibox` (`WhatwgURL`, `resolveInput` with `searchUrlPrefix(settings)`). The default `PlainWebAddressing` is for tests and parses only simple URLs. |
| `@solara/store` (JS) | Phase 1b, every state change | Push the one cache the core reads but JS computes: `setPlayingAudio` (tabs whose live state plays audio). `persist.ts`'s `nativeCaches` does it; a missing push leaves the core's guess stale without an error. History hints, the launch backdrop, the early launch tab and the last-tab policy are Swift's own (`NativeCaches.swift`, `HistoryHints.swift`, `NativeCacheFeeds.swift`); their old commands are accepted and ignored. |
| `@solara/store` (JS) | Phase 1b, JS module memory | Mirror each setter of memory the core reads: `setWindowClosing` (closing windows), `noteRemotePinDeletion`, and bracket sync writes with `beginFromSync`/`endFromSync` (`fromSync`). |
| `@solara/store` (JS) | Phase 1b, writes outside actions | Use `writeState` (owned slices go as `applyState`, JS-owned ones stay local) or the command. Anything else is forwarded by the guard, logged in `globalThis.__nativeStoreForwards` with its stack, and raised in Debug. |
| `NativeStore` | Scope switch | The whole workspace runs on the native store by default (1b), and the shadow export owns `session.json` and `downloads.json`. `SOLARA_NATIVE_SCOPE=settingsAndDownloads` falls back to the 1a scope. |
| `SolaraUI` New Tab | While a native New Tab is mounted | JS publishes the suggestion data the hero can't read natively: the profile's tabs, history and bookmarks, and the window's bar actions and extensions (`newTabSources` in `@solara/settings`, driven by `NativeNewTabHero.tsx`). A missing push leaves the hero's suggestions stale without an error. Settings come from `NativeStore.settingsModel`, so the hero is off (`SolaraNewTab.available()` is false) whenever native settings are. `SOLARA_NATIVE_NEWTAB=0` forces the RN page. |
| `SolaraUI` Pages | While a native internal page is mounted | JS sends the page's whole state as one JSON `state` prop (`NativeDownloadsPage`, `NativeHistoryPage`, `NativeBookmarksPage`): its rows, the theme tokens, and counters the page watches (history's selection reset, clear request and clear done; bookmarks' undo count). It runs every action the page sends as `onPageEvent` (open, delete, move, restore, clear), so the store stays JS's. A field the decoder can't read drops the whole update and the page keeps its last state without an error. `SolaraPages.available()` is false when native settings are. |
| `SolaraSignposts` | Each surface's endpoint | Call `SolaraSignposts.emit` at "selection shown", "suggestions shown", "core ready" and "New Tab painted", and `count` per store commit, Core Animation commit, layout pass and view update. In the RN era these are the `perfProbe` sites, through a native call. The baseline's `acmark.m` reads them, so a metric keeps its endpoint when its surface moves. |

---

## 5. The plan

Sizes are rough Swift lines, tests included. Every phase ships as nightlies first, then a stable release through the
full gate (`docs/perf/README.md`). Its perf is compared with the previous **stable** release, and the baseline's
metrics (§6) are re-run.

### 5.1 Phases

| Phase | Scope | Ships at the end | Measures | Size |
|---|---|---|---|---|
| **0. Baseline** | [baseline.md](baseline.md): the new probes (stall histogram, drag pacing, per-window memory, signposts) and one full run on the last RN stable | `docs/native/baseline-<version>.md` | Everything in §6 | about 800 (probes, orchestrator) |
| **1a. Core: settings, downloads** | SwiftPM package; Model / Store / Persistence (settings, downloads); RN bridge; JS settings actions → `dispatch`; `persist.ts` keeps writing `session.json` from the replica | Same UI, `solara.sqlite` source of truth for settings and downloads | Launch (J1) not worse; bridge round trip per `updateSettings` | 4–5k |
| **1b. Core: profiles + workspace** | All 114 actions; settle pipeline; `chromeChanged` / `stripPlan` in Swift (transactions forwarded by JS); the hidden writers removed; `session.json` importer + oracle; shadow export with `launchTab` / `launchBackdrop`; golden replay of the store tests | Same UI on the Swift store; `persist.ts` deleted | J1, J3, the ratchet's exact counts (must not rise); store dispatch p99 < 1 ms on the seed; save cost off the JS thread | 11–13k |
| **2. Settings, onboarding, utility windows** | Native Settings window (15 panes + sub-surfaces, below); Live engine port (`live/` → Swift, for Live Folders and Calendar); onboarding (5k TS); Import window | Native Settings; RN panes hosted until each ports; then no RN in utility windows | Settings open-to-content, pane switch, typing in search; memory with Settings open | 9–11k |
| **3. New Tab + internal pages** | New Tab (`NewTabPage.tsx`, `ntp/`, the sun hero, shader backdrop), `solara://history`, `bookmarks`, `downloads` pages | Native New Tab hosted in the RN window | ⌘T → typeable, ⌘T → painted | 3–4k |
| **4. Toolbar + omnibox** | `SolaraOmnibox` (port of `packages/core`, property tests against the frozen reference); toolbar, URL field, command bar, Developer Mode, find bar, downloads popover, site prompts, extension toolbar and overlays | Native toolbar and omnibox in the RN window | Keystroke → suggestions, compute per key, ⌘L, J4 | 8–10k |
| **5. Sidebar + window shell + sync port** | Sidebar (rows, tiles, groups, splits, Live Folders, DnD, list motion, swipes), top tab strip, content card, splits, Peek, media/PiP controls, Little Solara, `TabViewPool`; drag via `ServerWindowDrag`; sync merge to Swift | Browser windows with no RN; the early window reads the store | Tab switch, hover frames, drag pacing, stalls, memory per window, launch | 15–18k |

Phase 2 can start after 1a, while 1b is in progress. Its Profiles pane (fourth in the port order, §5.4) waits for
1b. Numbering: the brief calls Settings "phase 1's surface". Here phase 1 is the core with no surface, and Settings
is phase 2, the first surface.

### 5.2 Parity method: golden replay

`apps/browser/scripts/native/replay.mjs` runs action scripts through the real JS store in Node, the way the
`*.test.mjs` files already do, and records `(initial state, command list, resulting persisted state, effects)` as
JSON cases. `SolaraStoreTests` replays every case through the Swift core and diffs canonical JSON.
- Sources: all 7.5k lines of store tests, `liveTabs.test.mjs` with its fake engine (strip transactions as input,
  commands as effects), the sync adapter tests, and random sequences from a seeded generator over the 114 actions.
- "Behaves like today" becomes a diff that has to be empty. Once JS is gone, the cases stay as Swift's fixtures.

### 5.3 Acceptance checks per phase

All existing suites keep passing at every phase: the store, lib and sync tests (through replay once the JS is
gone), `acceptance.mjs`, `shortcuts-test.mjs`, `tab-drag-test.mjs`, `windowing-test.mjs`, `sidebar-click-test.mjs`,
`layout-shift-test.mjs`, `hover-shift-test.mjs`, `settings-shift-test.mjs`, `onboarding-test.mjs`. Solara's own
behaviors, checked where their phase lands:

| Behavior | Source | Checked in |
|---|---|---|
| ⌘D moves a tab to Pinned; bookmarking is ⌥⇧⌘D | 56e9f201 | 1b (command, menus), 5 (sidebar) |
| A tab close that takes the window asks first; the close-window dialog counts pinned tabs ("Close N tabs") | 750134ef, 69dba1e2, `closeIntent` | 1b (semantics), 5 (native alert) |
| Closing the last tab leaves a New Tab unless the policy closes the window (`closingTabs`, `leavesEmptyWindow`) | acc17272 | 1b, 3 |
| New Tab hero is the sun alone, on whole device pixels | 524f4047, 7104dc4d | 3 (pixel diff with the RN capture) |
| Developer Mode toolbar: 18 pt stripes falling right, 11 pt URL edited in place on the resting line, no not-secure lock on local hosts, window colors kept, reload chevron, DevTools buttons | be12e868, 1bd64609, 1ca81a98, 65266b4a, d34de431, 2d369f49, a8370ae3 | 4 |
| Tab titles run to the row's edge unless the row is hovered | 76669d61 | 5 |
| Tidy and Clear fade in when the divider row is hovered (120 ms in, 160 ms out, ease-out quad) while the line draws back by their width; divider full width at rest | 1a8400db, 538bfdd9, c3791ed3 (`ClearDivider.tsx`) | 5 |
| A group's box shows only under the pointer | e8ae23fb | 5 |
| Switching tabs shows the new page at once, with no fade | 719f4787 | 5 |
| Main windows open and close with Little Solara's motion | 3b1de139 | 5 |
| Tooltips show the bound key | 2c05816b | 4, 5 |

Visual checks compare against an RN capture with the same crop and state (AGENTS.md › "Match Dia with numbers").
Timings in frames are measured from 30 fps recordings.

### 5.4 Settings inventory (phase 2)

`PANES` (`settingsIndex.ts:5`) has **15** panes, not 17. The other surfaces are Profile details
(`ProfileDetailsPane`), the Theme editor (`ThemeEditor.tsx`, 571 lines) and Sync sheets (`SyncSheets.swift`).

| Pane | Lines | Kind | Native data source |
|---|---|---|---|
| General | 260 | Simple + system | `SettingsModel`; login item (`SMAppService`), default browser, `Updater.swift` (channel, auto-update), `SolaraCoreEngineBridge` `ac_downloads_settings` / `ac_downloads_set_settings`, default profile |
| Tabs | 198 | Simple | `SettingsModel` (`tabLayout`, `newTabPosition`, `newTabButtonPosition`, `newTabOpens`, `cleanUpInactiveTabsAfterHours`, sidebar button, haptics, website color, ⌘-click groups, meeting groups) |
| Appearance | 278 | Simple + app icon | `SettingsModel` (`appearance`, `addressBar`, `commandBarPlacement`, `pageScrollBars`, `spacesFollowAppearance`); app icon list from `AppIcon.swift` |
| Search Engine | 165 | Medium | `SettingsModel` + custom engine add/edit sheet (`addCustomEngine` validation from `SolaraOmnibox`); extension-controlled engine from `ac_search_engines` |
| Engines | 154 | Simple | `SettingsModel` (`pageEngine`, `websiteEngines`, `protectedVideoInWebKit`) |
| Advanced | 155 | Simple + info | `SettingsModel`; CLI install and control (`CliInstaller.swift`, `ac_cli_control`); `SolaraCoreHost.engineInfo`; Widevine from `SolaraCoreServices.components` |
| Privacy & Security | 366 | Data-heavy | Content blocker, site permissions, external app allowances, zoom levels and clear browsing data |
| Keyboard Shortcuts | 197 | Medium | Menu item list from `Menus.swift` (direct), `settings.shortcuts` remaps, recorder control |
| Passwords | 250 | Data-heavy, secrets | `SolaraCoreServices.listPasswords` / `unlockPasswords` (reauth) / `password` / `save` / `update` / `delete` / `neverSaveOrigins` / `exportPasswords`; CSV import via `SolaraImport` (`PasswordsCSV.swift`); password-autofill toggle via `boolPreference` |
| Autofill | 308 | Data-heavy, secrets | `SolaraCoreServices.addresses` / `saveAddress` / `cards` / `saveCard` / `deleteAutofillEntry` / `revealCardNumber`; enable toggles |
| Extensions | 213 | Data-heavy, live | `SolaraCoreServices.listExtensions` / `setExtension` / `uninstall` / `reload` / `configure`, `extensionsHandler` events; Web Store link, load unpacked (`inspectUnpacked`) |
| Profiles + details + Theme editor | 318 + 571 | Data-heavy | `AppModel` profiles; create / share-with / reorder / delete commands; clear data (`clearBrowsingData`, `deleteProfileData`); theme editor on `SolaraShaders` Metal views (already native) |
| Sync + sheets | 282 + 294 | Data-heavy, setup flows | `SyncModule` / `SolaraLegacySyncCore` (folder info, recovery phrase, recovery kit PDF/QR); sync state and devices from the TS engine until phase 5 (through the bridge), then `SolaraSync` |
| Live Folders | 348 | Data-heavy, OAuth | Live engine (ported in this phase): sources (GitHub, Notion, Google Drive; Bitbucket and Confluence dropped 2026-10-30), Google auth, connected accounts in the Keychain |
| Calendar | 114 | Data-heavy | `Calendar.swift` (EventKit) + Live state (`hiddenCalendarIds`, alert options), `autoGroupMeetingTabs` |

**Port order:**
1. The native shell, search and navigation, with every pane hosted from RN.
2. General, Tabs, Appearance, Search Engine, Engines, Advanced, Keyboard Shortcuts.
3. Privacy, Passwords, Autofill, Extensions.
4. Profiles and the Theme editor.
5. Sync.
6. The Live engine, then Live Folders and Calendar.
7. Onboarding.
8. The Import window.

---

## 6. Measurement baseline (summary)

Full definitions, tools and the script plan are in [baseline.md](baseline.md). **Nothing has been run yet.** The
baseline runs on the last RN stable after the overnight Chromium build ends, under the perflab lock, with the
display awake.

| Metric | Endpoint pair | Existing tool | New work |
|---|---|---|---|
| Tab switch click → response | The row's click event → CA commit showing it selected; → the new page's frame | `tab-actions.mjs` (sidebar click, ⌃Tab, ⌘1–9; it also splits out "main wait"), J3 | None |
| New tab | ⌘T key event → field typeable; → New Tab painted | `native-bench --only newtabkey` (J2), `tab-actions` ⌘T | None |
| Omnibox keystroke → suggestions | Key event → suggestion rows committed; compute alone per key | J2 `suggested` mark, `suggest-hermes.mjs` | A native signpost, so the metric survives the move |
| Sidebar hover | Pointer enters a row → hover in a CA commit; frames delivered over a 24-row sweep | Frame rig `hover`, census `hover` | None |
| Window drag frame pacing | Drag start latency (ms and pt), trail per frame (pt), frames delivered / expected, end error | None in the repo (746664cf used an uncommitted `drag.swift`) | `acperf postdrag`; needs a visible window (§7) |
| Main-thread stall histogram | Main and JS run-loop iterations bucketed 8 / 16 / 33 / 50 / 100 / 250 ms per scenario; samples of each ≥ 50 ms stall | `acframes.m` busy time (totals only), `acsample.c` (launch only) | Histogram output; `acsample` during scenarios, with attribution to Chrome / RN / app |
| Launch → first window | Process start → window shown → content → first frame → FCP; warm, cold (`--fresh-copy`), 1 tab and seed | `native-bench --only launch` | A "core ready" mark to replace "JS running" |
| Memory per window | Δ `phys_footprint` (browser) and Δ total (with helpers) per extra window, k = 1..4, settled | `native-bench` memory / newwindow | Slope variant |

The baseline defines every metric from native endpoints (AppKit event time, Core Animation commit, the page's frame).
`SolaraSignposts` (`os_signpost`) mark the same points in RN-era and native code, and a native ratchet (layout passes,
view updates and store commits per action) replaces the JS one in phase 6.

---

## 7. Risks and open questions

Each has a recommendation.

1. **The core port is large** (114 actions, a settle chain whose order matters, 7.5k lines of store logic).
   → Golden replay before any surface work (§5.2). Port by slice (1a, then 1b), and ship each slice as a nightly.
2. **The main thread stays Chrome's.** Native won't remove stalls Chrome causes.
   → The baseline's stall attribution (§6) splits main-thread time between Chrome, RN and app before we promise a
   number. The target is per interaction: no app work over 1 ms on main.
3. **Two writers creep back during the bridge** (29 `setState` sites, sync adapters, listeners).
   → The Debug guard (§4.3) plus the ratchet's exact counts.
4. **Sync wire compatibility.**
   → The merge stays TS until phase 5, then is held by cross-implementation fixtures (§4.5).
5. **Rollback depends on the shadow `session.json`.**
   → Keep it until phase 6 plus two stable releases. It costs one 21 KB write every 2 s at most, off main.
   *Open question: is that window long enough?*
6. **Event order between strip transactions and WebView events** while the views are still RN's.
   → JS forwards transactions as commands until phase 5 (§2.6). The `liveTabs.test.mjs` replay cases include
   adoption-then-transaction orderings.
7. **Mixed RN / native focus and key handling** (hosted views in phases 2–4).
   → A focus case per hosted kind in `shortcuts-test.mjs`. Native key equivalents go first through `Menus.swift`,
   as today.
8. **Drag pacing can't be measured hidden.** Real HID drags need a visible, unoccluded window, and posting in-process
   skips the window server path that matters.
   → *Open question:* may we schedule a 10-minute run with the owner away from the Mac but the screen unlocked, with
   the instance visible? Otherwise the drag row stays "needs owner run".
9. **Deployment target.** The app targets macOS 14. Observation works there; `Mutex` needs macOS 15, and newer
   SwiftUI APIs and (unverified, to check first) AppKit's own Observation tracking need later releases.
   → *Open question:* raise the minimum for the native app? Recommendation: yes, to the newest macOS whose APIs we
   confirm we use, since Solara has no users to migrate yet. It removes the Liquid Glass fallbacks
   (`liquidGlassOnly` rows) and possibly the helper in §2.5.
10. **Where the package lives.**
    → Recommendation: `native/SolaraKit`, outside `packages/` (Expo's workspace), so phase 6 deletes `packages/*`
    except SolaraCore without moving the core. *Open question if the owner prefers `packages/solara-core`.*
11. **Hermes-side services nobody sees.** `main.tsx` starts: translate, user scripts, CLI control, memory trim, tab
    lifecycle, app integration (AppleScript), kill switches.
    → Each gets a row in phase 6's checklist and is ported, except kill switches, which are deleted (Solara has no
    switches URL).
12. **GRDB as a dependency.**
    → Pin the exact version and checksum in `Package.resolved`, and add it to the supply-chain review. Owner's choice
    already; noted only for the pin.
13. **Size of onboarding** (5k lines, demos).
    → Port it last in phase 2. It reuses the Metal views as they are.

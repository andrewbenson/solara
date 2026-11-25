# Swift command ownership plan

Base: `655b2a783a60bf2bf0f1161e88310b310b1e7895` (main HEAD). Scope: inventory every browser command, then implement tabs/windows only. This is the first part of roadmap 0.4.2's command row; the complete row remains unfinished until navigation, focus and the other groups also work with JS handlers disabled.

## Current dispatch and ownership

`packages/shell/ios/Menus.swift` constructs menus, aliases, key equivalents, responder actions and validation. `AppModule.swift` arbitrates shortcut precedence. `MenuTarget.performCommand` first tries `NativeMenuCommands.argumentHandlers`, then `handlers`, then emits through `ShellModule`'s `onCommand`. `apps/browser/src/lib/native.ts` passes that event through `settlingCommandFocus` to `lib/commands.ts:runCommand`. `runCommand` also receives omnibox/developer callers. It handles utility windows, Little Solara and Peek before its main switch, and delegates sidebar commands to `components/sidebar/commands.ts`.

`nativeOwnsWorkspace()` in JS and `NativeStoreHandle.ownsWorkspace` in Swift are the existing full-workspace ownership checks. A native store reducer already existing does not mean its command orchestration is native: confirmation, target selection, focus, window materialization and page effects can still be JS decisions. The inventory's column b correctly classifies these bridges as behavior. Native services should consume the existing store API; do not copy reducers into menu code.

Legend: **E** = existing native implementation; **R** = reducer/page primitive exists but Swift command routing/orchestration must be added; **N** = new native behavior/action needed. Unless named otherwise, the current JS handler is the same-named case in `lib/commands.ts:runCommand`. `Store` below means commands dispatched to `native/SolaraKit/Sources/SolaraStore`; page operations mean `SolaraUI/TabPool/PageCommand` issued through `PageIssuer`.

## Tabs

| Command | Current JS handler | Swift owner/action | State |
| --- | --- | --- | --- |
| `newTab` | `toggleNewTabBar`, then `s.newTab(windowId,{newTabCommand:true})`; no window calls `openWindow` | Native command router calls canonical Store `newTab` with `newTabCommand:true`; create window only when no usable window. Separate + New Tab job owns placeholder semantics. | R |
| `closeTab` | Panel dismissal, Peek/find dismissal, multi-selection, `lib/actions.closeTab` | Native router owns precedence; Store `closePanel`, `setFind`, `closePeek`, `closeTabs`; native close policy/confirmation and shell animation | R/N orchestration |
| `reopenClosedTab` | `store/closedTogether.reopenClosedTogether`, then `s.reopenClosed` | New Store `reopenCommandClosed` restores a native close-together receipt, else existing `reopenClosed` | R/N receipt action |
| `restoreClosed` | `s.restoreClosed(arg,windowId)` | Store `restoreClosed` | R |
| `duplicateTab` | `s.duplicateTab(activeTab)` | Store `duplicateTab` | R |
| `nextTab`, `previousTab` | `s.cycle(windowId,±1)` | Store `cycle` | R |
| `selectTab`, `selectLastTab` | `numberedTabs`, `s.activate` fallback | `NativeNumberedTabs` already routes Store `activateNumberedTab`; `SidebarQuery.numberedRows` is canonical row order | E |
| `moveTabDown`, `moveTabUp` | `s.moveTabBy(activeTab,±1)` | Store `moveTabBy` | R |
| `moveTabToWindow` | `lib/actions.moveTabToWindow`, target `new` becomes null, then focus | Store `moveTabsToWindow`, native window materialization/focus | R |
| `moveTabToProfile` | `lib/actions.moveTabToProfile`; optional creation and warning | Store `moveTabToProfile`; native profile-creation dialog and cross-engine warning | R/N orchestration |
| `newTabInGroup` | `runSidebarCommand`: new-tab bar/group targeting, `s.newTabInGroup` | Store `newTabInGroup`; native command target policy | R |
| `newGroupWithTabs` | `sidebar/actions.newGroupWithSelection` | Store `createGroup`/`groupTabs`; native naming/presentation | R |
| `closeTabGroup` | `lib/actions.closeGroup` with warning | Store `closeGroup`; native close-group confirmation | R |
| `closeAllTabs` | `sidebar/menus.closeAllTabs` | Store `clearUnpinnedTabs`; native close confirmation/undo presentation | R |
| `cleanUpTabs` | `s.cleanUpTabs` | Store `cleanUpTabs` | R |
| `tidyPins` | `sidebar/tidyPinsUi.tidyPins` | Store `tidyPins`/`untidyPins`; native result presentation | R |
| `renameTab` | `sidebar/actions.startRename` | Store `updateTab`; native rename presenter | R |
| `changeTabIcon` | `sidebar/actions.openIconPicker` | Store `updateTab`; native icon picker presenter | R |
| `togglePin` | `s.togglePin`/`pinTabs`, variant-aware | Store `togglePin`/`pinTabs` | R |
| `togglePinnedRow` | `sidebar/movePinned.togglePinnedRows` | Store `pinTabs`; native selection/section policy | R |
| `returnToPinnedUrl` | `s.returnToPinnedUrl` | Store `returnToPinnedUrl` | R |
| `toggleMute` | `lib/actions.toggleMute`: state and live webview | Store `setSiteMuted` plus page `.setMuted` | R |

## Windows

| Command | Current JS handler | Swift owner/action | State |
| --- | --- | --- | --- |
| `newWindow` | `lib/actions.openWindow`, `store/small.newWindowProfile` | Store `createWindow`; native profile resolution and window reconciler | R |
| `newIncognitoWindow` | `openWindow({incognito:true,profileId:originalProfile(...)})` | Store `createWindow` with incognito options; native window reconciler | R |
| `newLittleSolara` | `littleSolara/actions.openLittleSolara` | Store `createWindow(kind:small)` and native small-window presenter/adoption | R/N orchestration |
| `reopenClosedWindow` | `s.reopenClosedWindow` | Store `reopenClosedWindow`; native window reconciler | R |
| `mergeAllWindows` | `s.mergeAllWindows` | Store `mergeAllWindows`; native reconcile/focus | R |
| `std:closeWindow:` | Already `MenuTarget.closeWindow` → `performClose`; JS `windowClose.requestClose` decides close request | Native close-request hook, retain-last-window policy, warnings, animation and Store `closeWindow` | E shell/R orchestration |
| `toggleOpenLinksInLittleSolara` | `s.updateSettings` | Store `updateSettings` | R |

Native window lifetime must not depend on `lib/windowSync.ts`: it currently opens/closes NSWindows after store mirrors change, forwards focus/frame/fullscreen and confirms close notifications. Wire native-created and native-closed windows directly to shell services under native ownership, leaving this JS reconciliation only as fallback. Preserve private-session effects and before-unload cancellation; never dispatch a second close from both owners.

## Navigation and page operations

| Command | Current JS handler | Swift owner/action | State |
| --- | --- | --- | --- |
| `back`, `forward` | `layout/history.goBack/goForward`, including native navigation history target rules | Native history target policy; page `.goBack`/`.goForward`/`.goToOffset`, Store navigation as required | R/N policy |
| `reload`, `forceReload` | `withLivePage` and webview reload/forceReload | `PageIssuer` wake/admission, page `.reload`/`.forceReload` | R |
| `stop` | webview `stopLoading` | Page `.stopLoading` | R |
| `openFile` | `openFiles` uses shell picker and newTab; Peek promotes, Little Solara expands | Native file picker + Store `newTab`/`createWindow`; Peek/Little Solara routing | R/N orchestration |
| `openBookmark` | Direct native ID request; bookmark open adapters bypass the mirror | `BookmarkMenuCommand` and `NativeBookmarkCommands`, original-profile owner snapshot and canonical navigation | Swift source present; VM verification pending |
| `togglePageEngine` | `lib/engines.togglePageEngine` | Native engine-switch policy, page registry replacement and Store `updateTab` | N orchestration |
| `savePage`, `caretBrowsing`, `printWithSystemDialog` | webview `runPageCommand(savePage/caretBrowsing/systemPrint)` | Page `.runPageCommand` | R |
| `print` | webview `print` | Page `.print` | R |
| `copyUrl` | `site/selection.copyPageUrl` | Native clipboard and page URL resolution | R |
| `copyUrlAsMarkdown` | `markdownLink`, shell `copyText` | Native URL/title formatter + clipboard | N formatter |
| `emailPageLocation` | HTTP(S) guard + shell `openExternalURL(mailto:)` | Native mail URL encoder/NSWorkspace | N routing |
| `share` | `site/share.shareTab` | Native `SharePicker`/`ShareContent`, native active-page resolution | R |
| `cast` | `media/cast.toggleCastPicker` | Native cast picker + engine service | R/N lifecycle |
| `autofill` | `site/Autofill.requestAutofill` | Native active-page/profile resolution + Chrome autofill UI | R |

## Focus and find

| Command | Current JS handler | Swift owner/action | State |
| --- | --- | --- | --- |
| `focusCommandBar` | Developer URL edit, omnibox panel, empty-card/new-tab bar or hero focus; `focusClaims` | Native command focus resolver, existing `FocusHandoff`/`FocusMoves`, omnibox/hero controllers; Store `openPanel`/`closePanel` | N policy/R primitives |
| `searchTabs` | Sidebar search state | Native sidebar search presenter | N routing |
| `tabSwitcher` | `sidebar/switcher.switcherStep`; shell `SwitcherHold` tracks release | Native switcher state/selection controller; Store `activate` | N behavior |
| `findInPage`, `findAndReplace` | `s.setFind` and focus claim | Store `setFind`, native FindBar focus | R |
| `findNext`, `findPrevious` | Open find if no query, else webview `find` | Store `setFind`; page `.find` | R |
| `useSelectionForFind` | page evaluate selection then `s.setFind` | Native page selection query + Store `setFind` | R |
| `jumpToSelection` | Direct native workspace-command bridge; no JS handler | `PageMenuCommand` resolves the page; `PageIssuer` evaluates the selection scroll operation | Swift source present; VM Swift/driver verification pending |

## View, settings and app services

| Command | Current JS handler | Swift owner/action | State |
| --- | --- | --- | --- |
| `setAppearance` | Store setting then shell appearance | Store `updateSettings`; native appearance service | R |
| `toggleFullUrl`, `toggleJavaScriptFromAppleEvents`, `toggleAddressBar` | `s.updateSettings` | Store `updateSettings` | R |
| `setSidebarPosition` | `store/sidebarRail.setSidebarPosition` | Store `setSidebarPosition` | R |
| `toggleSidebarIconsOnly` | `store/sidebarRail.toggleSidebarIconsOnly` | Store `setWindowSidebar` + native toggle policy | R |
| `toggleTabLayout` | `s.toggleTabLayout` | Store `toggleTabLayout` | R |
| `toggleSidebar` | `s.toggleSidebar` | Store `toggleSidebar` | R |
| `zoomIn`, `zoomOut`, `zoomReset` | webview `zoomStep(1/-1/0)` | Page `.zoomStep` | R |
| `downloads` | `s.setDownloadsOpen` | Store `setDownloadsOpen` | R |
| `openSettings`, `keyboardShortcuts` | `settings/windows.openSettings`, with pane | Native Settings window presenter | R |
| `importBrowserData` | `settings/windows.openImport` | Native Import presenter/RPC owner | R |
| `showOnboarding`, `toolTour`, `videoTour`, `releaseNotes` | `nativeAppIntegrationCommand` | `NativeAppStartup` already installs direct native handlers | E |
| `sendFeedback`, `copyDiagnostics`, `recordPerformanceIssue`, `taskManager` | `nativeAppIntegrationCommand` | `NativeAppIntegration` already installs direct native handlers | E |
| `openExtension` | `extensions/bridge.openExtensionFromMenu` | Native extension action/popup coordinator | R |
| `addExtension` | `extensions/state.openWebStore` | Native web-store opener + Store `newTab` | R |
| `manageExtensions`, `pinExtensions` | `extensions/state` dialog/window state | Native Settings/extensions presenters | R |

## Profiles

| Command | Current JS handler | Swift owner/action | State |
| --- | --- | --- | --- |
| `switchProfile` | `lib/actions.switchProfile`/native profile pager; Little Solara moves instead | Native pager/profile resolver; Store `switchProfile`; small-window move behavior | R |
| `nextProfile`, `previousProfile` | `cycleProfile`, shell pager step then JS fallback | Native pager target resolver; Store `switchProfile` | R |
| `newProfile` | `createProfile` prompt then `switchProfile` | Native create-profile presenter + Store `createProfile`/`switchProfile` | R |
| `openProfileMenu` | `ProfileIndicator.openProfileMenu` or Little Solara profile menu | Native profile menu presenter with private-window guard | R |

## Split

| Command | Current JS handler | Swift owner/action | State |
| --- | --- | --- | --- |
| `openSplitPane` | `layout/splitActions.openSplitPane`, error toast/focus | Store `openSplitPane`; native result/focus/toast orchestration | R |
| `focusNextPane`, `focusPreviousPane` | `s.focusPane(windowId,±1)` | Store `focusPane`; native page focus | R |

## Bookmarks

| Command | Current JS handler | Swift owner/action | State |
| --- | --- | --- | --- |
| `bookmarkPage` | `bookmarks/actions.bookmarkTab` | Native bookmark form + journal writer | R |
| `addBookmarkToFolder` | Optional folder prompt, `bookmarkWriter.addBookmarkFolder/addBookmark` | Native bookmark catalog/writer + folder prompt | R |
| `bookmarkAllTabs` | `bookmarks/actions.bookmarkAllTabs` | Native bookmark form/writer + native eligible-tabs query | R |
| `manageBookmarks` | `openInternalPage(bookmarks)` | Native internal-page opener + Store `newTab`/`navigate` | R |
| `addFolderToSidebar`, `restoreArcFolders` | `lib/bookmarkGroups` projection/restoration | Native bookmark catalog + Store `createGroup`/`newNestedGroup`/`newTab` | N orchestration |
| `setBookmarksBar`, `toggleBookmarksBar` | Settings with current-page visibility rule | Store `updateSettings`; native visibility resolver | R |

Native bookmark menu data already comes from `NativeBookmarkMenuSource`; that does not yet make its command actions native.

## History

| Command | Current JS handler | Swift owner/action | State |
| --- | --- | --- | --- |
| `showHistory` | `openInternalPage(history)` | Native internal-page opener + Store `newTab`/`navigate` | R |
| `clearBrowsingData` | Open history, `useClearDataRequest.request` | Native history/clear-data presenter + engine service | R |

Recently Closed menu entries invoke `restoreClosed` (tabs group above); Recently Closed Groups is likewise restored by that store action.

## Developer

| Command | Current JS handler | Swift owner/action | State |
| --- | --- | --- | --- |
| `devTools`, `toggleDevTools`, `inspectElements`, `javaScriptConsole` | webview `showDevTools` with default/toggle/inspect/console | Page `.showDevTools` through `PageIssuer` | R |
| `toggleDeveloperMode` | `site/developerMode.toggleDeveloperModeFor` | Native site preference/URL editor policy | N orchestration |
| `viewSource` | Scheme guard then `s.newTab(view-source:...)` | Native command guard + Store `newTab` | R |

## Standard responder actions

The remaining `STANDARD_ITEMS` already run through AppKit's responder chain: quit/hide/hide-others/show-all; undo/redo; cut/copy/paste/paste-and-match-style/delete/select-all; spelling/grammar/correction; substitutions/smart insert-delete/quotes/dashes/links/data/text replacement; uppercase/lowercase/capitalize; start/stop speaking; fullscreen/minimize/minimize-all/zoom/arrange-in-front/keep-on-top. Keep these native. The `undoReopensClosedTab` branch must call the same native reopen router rather than directly emitting the JS handler. Close Window's native selector still needs native lifecycle ownership as recorded above.

## First implementation: tabs and windows

- [ ] Add `WorkspaceMenuCommand.plan(command,arg,windowId,state) -> WorkspaceMenuPlan`, with `commands:[Command]`, optional `close:WorkspaceCloseIntent` and optional `focusWindow:String`. Close intents are `tabs(windowId,tabIds)` or `window(String)`. It resolves targets using native state; unknown commands return unhandled. `NativeWorkspaceCommands` registers ownership-gated shell argument handlers and `WindowHost.closeRequest`; native-owned recognized commands do not fall through after a no-op or invalid argument.
- [ ] Route new/close/reopen/restore/duplicate/cycle/move/select-by-number and new/close/reopen windows through it. Use canonical `newTab` with `newTabCommand:true`; do not encode the separate placeholder design here. Reuse `activateNumberedTab` and native sidebar numbering.
- [ ] Add native close precedence and confirmations for utility/small/Peek/panel/selection/last tab, close-together restoration, and native window lifecycle/reconciliation as needed. New Store `closeCommandTabs`/`reopenCommandClosed` actions retain the multi-close receipt in `StoreMemory`, using existing reducers for the mutations. Guard ownership and stale modal/animation completion; preserve cancellation and private profiles. Retain JS branches as ownership-gated fallback.
- [ ] Swift tests cover each command, missing/invalid targets, no-window new tab, private/profile resolution, multi-window isolation, numbered rows (including last), movement, close warnings/cancel, panel/Peek precedence, last-window behavior and reopen. No Swift test or build runs on the owner's Mac.
- [ ] Add `scripts/*-test.mjs` driver that disables JS command handling, issues actual menu/shortcut commands, verifies native state and real windows, and fails if it silently exercises the fallback. Run only `node --check` here; run driver in VM.
- [ ] Allowed local verification: existing-node_modules `pnpm typecheck`, per-package browser/core JS unit tests, `node --check` and source reread. Never root `pnpm test`, installs, builds or any Solara launch. Record exact VM build/Swift-test/driver commands in `result.md`.
- [ ] Update roadmap/inventory to partial/in-progress truthfully, then produce `fix.patch` against base with new files included and `result.md`. No commits or push.

New Store actions `closeCommandTabs`/`reopenCommandClosed` preserve the close-together receipt; `restoreCommandWindow` restores a cancelled close from native undo state. Existing mutation primitives remain canonical. New Swift ownership also covers the user-command resolver, close policy and window lifecycle orchestration.

## Implementation evidence

Source implementation is present: `WorkspaceMenuCommand` resolves the first group, `WorkspaceClosePolicy` decides close warnings and stale-animation admission, and `NativeWorkspaceCommands` owns native command effects. The shell's menu, undo, close-request and developer paths reach native ownership; direct JS callers try the native bridge first. New/closed windows from these commands are materialized in Swift; the existing JS window mirror remains idempotent glue and still owns unrelated lifecycle feeds.

Swift tests and the handler-disabled native driver are written. `node --check` and whitespace checks pass. Compile, Swift test and hidden-instance checklist items remain pending VM execution. Local typecheck and JS tests are skipped because this clone has no `node_modules`. Exact commands are in `result.md`. No commits or push.

Copy links and share: Swift source delivered in slice 3; CopyLinkCommandTests and handler-disabled copy/quote/share drivers in layouts 0 and 1 remain VM gates. No build or runtime verification claimed.

# React Native removal inventory

Snapshot: `ba15bc0b8dc72c96f6ad51bba708318a014e19a8` on main. Audited on 2026-11-02.

Scope: 388 non-test `.ts`/`.tsx` files under `apps/browser/src`. Total: 54,494 lines.
Excluded: `*.test.*` and six test doubles in `src/test-native/` (770 lines).
Suffix filtering alone finds 394 files and 55,264 lines. The test doubles explain the difference.
The two `sync/fixtures/pinned-v0.2.*.ts` files remain included. They do not use test filenames.
Counts use `wc -l` on every included file. They include blank lines and declarations.
No builds, launches, tests, dependency changes, or Git writes were run.

Each file has one primary column. Mixed files name secondary columns in the appendix.
The choice follows the file's dominant responsibility. Whole-file lines go to that column.
An a count includes retained fallback drawing code. It is not a count of live release UI.
A b/d file can contain some a work. For example, `ContentCard.tsx` has drawing and page lifecycle code.
Types, constants, and export facades follow their owning data or glue module.
Transparent layout containers around native content count as glue, unless interaction policy dominates.
Theme resolution, ranking, geometry, and gesture thresholds count as behavior. They do not draw pixels themselves.

| Column | Primary responsibility | Files | Lines |
| --- | --- | ---: | ---: |
| a | RN pixels | 56 | 12,097 |
| b | Behavior | 194 | 24,435 |
| c | Data | 77 | 13,639 |
| d | Glue | 61 | 4,323 |
| Total | All included files | 388 | 54,494 |

## Findings that set the order

1. The New Tab extras still draw RN pixels on the normal native path. The bookmarks bar is native only; without it (development with the native shell off or `SOLARA_NATIVE_BOOKMARKS_BAR=0`) no bar shows. Extension popup frames also remain in RN.
2. Native controls still depend on JS actions, menus, focus, navigation, import, media, and window orchestration.
3. Native workspace ownership is already the default. It does not remove JS sync, library reconciliation, caches, or migration work.
4. A native window shell still wraps an RN main root. Browser pane roots add more RN roots. Native UI switches do not disable the RN runtime.

These are source findings. Runtime reachability, visual parity, and root counts in an actual release are **unverified** because the task forbids launching or building.
Native counterparts below prove that code exists. They do not establish complete behavioral parity.

## Release lanes and ownership gates

| Gate | Checked source | Meaning |
| --- | --- | --- |
| Shipped UI defaults | `native/SolaraKit/Sources/SolaraModel/LaunchSwitches.swift:28`, `:71`, `:199` | Native shell, top strip, bookmarks bar, side panel, shell panes, pages pool, and main-on-top default on. Distribution ignores their environment and stored overrides. Distribution is signing-derived or `SOLARA_RELEASE_LAUNCH=1`; it is not every Xcode Release build. |
| Safe mode | Same file, `:159`, `:223`; `packages/store/ios/NativeStore.swift:149` | Safe mode keeps native UI. Full in-memory ownership can remain native while persistence narrows to settings/downloads. It holds sync and unsafe operations. |
| Workspace ownership | `packages/store/ios/NativeStore.swift:15`; `src/store/nativeStore.ts:40`, `:65` | Default scope is everything. `nativeOwnsWorkspace()` requires active native store plus full scope. `SOLARA_NATIVE_SCOPE=settingsAndDownloads` remains a separate escape hatch, including distribution. |
| Native settings, toolbar, pages, hero | `packages/store/ios/NativeStore.swift:165`; `packages/settings/ios/{NativeSettingsWindow,Toolbar/ToolbarModule,Pages/PagesModule,NewTab/NewTabModule}.swift` | Availability follows the opened native settings handle. These are release paths, not debug-only implementations. Store failure can show native `StoreUnavailableView`. |
| Hosted capabilities | `packages/settings/src/hosted.tsx:19`; `packages/settings/ios/Hosted/{HostedViews,HostedModule}.swift` | `hostedKinds()` reports capability names, not mounted views. Missing module/errors yield an empty list. Some capabilities deliberately have nil view factories. |
| Top strip | `src/components/layout/NativeTopStrip.tsx:32`; `NativeStripControls.tsx:11`; `packages/settings/ios/TopStrip/NativeTopStrip.swift:107` | `nativeTopStripEnabled`, `nativeStripPeekEnabled`, and `nativeStripControlsEnabled` cache hosted-kind membership. RN fallbacks remain. Registration is asynchronous; first-read timing is **unverified** without a launch. |
| Full sidebar column | `src/components/sidebar/NativeSidebar.tsx:57`; `src/components/Sidebar.tsx:37` | Needs hosted sidebar shell, active native window, and native-owned profile pager. Sidebar address mode also needs native omnibox/address-bar capability. RN header/footer/dots remain fallback. |
| Actual native page pool | `packages/settings/ios/TabPool/TabPoolHost.swift:13`; `src/lib/pagesPool.ts:3` | Needs native split configuration, pane-root factory, opened store, ownership at launch, and `SOLARA_TAB_POOL != 0`. JS also checks shell/pane/pool availability. `windowPagesPoolActive()` alone is only a configuration flag. |
| Pane handoff | `src/components/ContentCard.tsx:419`, `:588` | The main-root fallback remains until the pane root reports a real layout. Pooled native prompts suppress the old RN prompt components. |
| Persistence | `src/lib/persist.ts:108`, `:253`, `:382` | Full native scope attaches a replica and skips JS session writers. Partial scope or absent native module can use JS workspace persistence. Present-but-inactive native store fails closed. |
| Sync redesign | `src/sync/redesignSwitch.ts`; `packages/store/ios/StoreModule.swift:66`; `LaunchSwitches.swift:70` | Default off. Development override requires an isolated data directory. Journal/password redesign code is not evidence that the shipped sync path is native. |

## Module totals

All numbers are whole-file `wc -l` counts. Group membership follows the path, with layout files split by surface.
The root `legacy.ts` is Bootstrap. Generic library helpers stay in Lib.
`components/onboarding/personalize.tsx` and `ui.tsx` stay in Onboarding even though the live NTP reuses them.

| Group | Files | a lines | b lines | c lines | d lines | Total lines |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| Bootstrap | 6 | 43 | 74 | 51 | 133 | 301 |
| Shared UI | 8 | 409 | 0 | 0 | 170 | 579 |
| Window layout | 20 | 406 | 1,664 | 11 | 193 | 2,274 |
| Page hosting | 14 | 456 | 1,454 | 321 | 256 | 2,487 |
| Split panes | 9 | 461 | 315 | 23 | 171 | 970 |
| Sidebar | 37 | 1,161 | 2,375 | 31 | 1,020 | 4,587 |
| Top strip | 6 | 1,754 | 315 | 0 | 412 | 2,481 |
| Toolbar | 9 | 1,108 | 282 | 0 | 316 | 1,706 |
| Omnibox | 16 | 0 | 1,287 | 67 | 80 | 1,434 |
| New Tab | 8 | 544 | 123 | 117 | 75 | 859 |
| Bookmarks | 6 | 442 | 345 | 0 | 0 | 787 |
| Profiles | 4 | 261 | 80 | 0 | 0 | 341 |
| Settings | 18 | 311 | 1,034 | 647 | 131 | 2,123 |
| Onboarding | 9 | 213 | 66 | 501 | 134 | 914 |
| Import | 3 | 0 | 329 | 101 | 0 | 430 |
| Internal pages | 11 | 0 | 358 | 0 | 53 | 411 |
| Downloads | 3 | 654 | 43 | 0 | 43 | 740 |
| Extensions | 9 | 984 | 532 | 435 | 0 | 1,951 |
| Site and prompts | 22 | 2,084 | 1,168 | 0 | 91 | 3,343 |
| Media | 13 | 55 | 643 | 240 | 146 | 1,084 |
| Peek | 5 | 239 | 225 | 0 | 56 | 520 |
| Little Solara | 3 | 129 | 323 | 0 | 0 | 452 |
| Live cards | 6 | 383 | 121 | 0 | 156 | 660 |
| Live services | 12 | 0 | 602 | 75 | 216 | 893 |
| Store | 47 | 0 | 5,504 | 2,844 | 169 | 8,517 |
| Sync | 18 | 0 | 87 | 5,716 | 1 | 5,804 |
| Lib | 66 | 0 | 5,086 | 2,459 | 301 | 7,846 |
| Total | 388 | 12,097 | 24,435 | 13,639 | 4,323 | 54,494 |

## Native coverage and remaining dependencies

Path keys: `UI/` = `native/SolaraKit/Sources/SolaraUI/`; `Store/` = sibling `SolaraStore/`; `Sync/` = sibling `SolaraSync/`.
`Live/` and `Persistence/` are sibling `SolaraLive/` and `SolaraPersistence/`.
`Settings/` = `packages/settings/ios/`; `Shell/` = `packages/shell/ios/`.
Brace lists name separate files. All listed native filenames end in `.swift` unless stated.
“Default” means the source-selected normal distribution lane with full store ownership and available capabilities.

| Group | Native code already present | RN lane and work that blocks removal |
| --- | --- | --- |
| Bootstrap | `apps/browser/macos/Solara-macOS/AppDelegate.swift`; `Shell/{Windows,AppModule}`; `Settings/Services/NativeAppStartup` | Always boots JS on the normal entry. Move service startup, first-window ordering, skew/error presentation, and root creation. The native shell still retains the main RN root. |
| Shared UI | `UI/Primitives/{PopoverView,PopoverBubbleView,IconRing,CornerBadge,TabBadgesView}`; `UI/Settings/SettingsControls`; native primitives exposed through shell | RN buttons, switches, tooltips, icons, and error UI survive through callers. Replace live consumers, then remove retained fallback widgets. Native store-unavailable UI does not replace every `AreaBoundary` error path. |
| Window layout | `UI/WindowShell/{WindowShellView,SidebarDock,DockAnimator,DockMotion,ShellGeometry,FrozenPageView}`; `Settings/WindowShell/NativeWindowShell`; `Shell/ChromeWindows` | Native shell/dock default. RN still composes the window and feeds geometry, backdrop, modal state, profile paging, and drag targets. RN dock/tint branches remain fallback. |
| Page hosting | `UI/TabPool/{TabViewPool,PageIssuer,PageRegistry,RNPageCallPolicy}`; `UI/PaneOverlays/{PaneRoots,PaneOverlays,SadTabView,SwipeCapsuleView}`; `Settings/{TabPool/TabPoolHost,PaneOverlays/NativePaneRoots,PaneOverlays/PanePrompts}` | Native engine-page pool default when available. RN `ContentCard`, page events, planning/props, overlay hints, and root handoff remain live. Move that orchestration and native fallback/error coverage before removing roots. |
| Split panes | `UI/Split/{SplitChromeView,SplitPanesView,SplitSlots,SplitDividerView,SplitDropZonesView,SplitEmptyStateView}`; `Settings/Split/NativeSplitChrome`; `Store/Splits` | Native pooled chrome default. JS still chooses pane actions, feeds toolbars/toasts, and retains sizing/drop/empty-state fallbacks. Native chrome alone does not remove JS commands. |
| Sidebar | `UI/Sidebar/{SidebarView,SidebarChrome,SidebarFolderPanel,SidebarGroupCard,SidebarIconPicker,SidebarHoverSurface,TabSearchPanel,TabSwitcherPanel}`; `Settings/Sidebar/{NativeSidebar,NativeSidebarShell,NativeSidebarDock,NativeSidebarHoverCard,NativeTabPickers}` | Rows and full column are native by default gates. JS still feeds theme/media/live/selection and handles menus, rename, close, search, hover, folder, and drop choices. Header/footer/group/hover pixels remain fallback. |
| Top strip | `UI/TopStrip/{TopStripView,StripPageView,StripControls,StripPeekView,StripDrag,StripContext,StripLayout}`; `Settings/TopStrip/{NativeTopStrip,NativeTopStripPeek}`; `Store/StripQuery` | Native default; 1,754-line RN strip remains behind capability checks. Move JS callbacks, group/folder menus, entry policy, and reorder policy. Verify cached registration timing before calling the fallback dead. |
| Toolbar | `UI/Toolbar/{ToolbarView,ToolbarState,ToolbarUrlFieldView,SidebarAddressBarView}`; `UI/Find/FindBarView`; `UI/AutoHide/ToolbarAutoHide`; `UI/Panels/HistoryPanelView`; `Settings/{Toolbar/ToolbarModule,Find/FindBarModule,AutoHide/AutoHideModule}` | Native toolbar/find default. JS still builds button/state JSON, handles clicks, history, URL edits, translation, focus, replace, and visibility. RN toolbar/find/history bodies remain fallback. |
| Omnibox | `UI/Omnibox/{OmniboxBarView,OmniboxPanelHostView}`; `UI/NewTab/{HeroBarModel,OmniboxCommandSources,OmniboxWorkspaceSources,OmniboxCommandCatalog}`; `Settings/Omnibox/{NativeOmniboxView,NativeOmniboxSources}` | Native fields/suggestions; JS still owns open/switch dispositions, action dispatch, clipboard menus, file chips, focus, and extension/action feeds. Workspace-tab feed is suppressed under native-source mode. |
| New Tab | `UI/NewTab/{NewTabHeroView,HeroBarContent,HeroField,BarSurfaceView,NewTabLayout}`; `Settings/NewTab/{NativeNewTabView,NewTabModule}` | Hero is native-only. NTP extras remain live RN: personalization, feedback check-in, release postcard/page. No native counterpart for those complete NTP surfaces was found. Move their pixels, state, and geometry. |
| Bookmarks | `UI/Pages/{BookmarkFormView,BookmarksPageView}`; `Settings/Pages/PagesModule`; `Settings/NativeHistoryCatalog` | Dialogs are native. The bookmarks bar is native (`SolaraUI/BookmarksBar`, `Settings/BookmarksBar`); `NativeBookmarksBar.tsx` only feeds it state and runs its actions. JS also owns edit/menu/undo and Chrome reconciliation. |
| Profiles | `UI/Pages/CreateProfileFormView`; `UI/Settings/Panes/{ProfilesPane,ProfileDetailsPane,ProfileSheets}`; `UI/Sidebar/SidebarChrome`; `Store/ProfileActions` | Create form is native. Indicator/dots are RN fallback when the full native column is unavailable. JS still selects profile defaults, dispatches creation, and supplies form data. |
| Settings | `UI/Settings/{SettingsWindowView,SettingsNavigation,SettingsSearch,SettingsIndex}`; `UI/Settings/Panes/{GeneralPane,SyncPane,PrivacyPane,PasswordsPane,AutofillPane,ExtensionsPane,ThemeEditor}`; `Settings/{NativeSettingsWindow,SettingsJS,Adapters/SettingsAdapters}` | Native auxiliary window by default. JS topic/RPC server still services profiles, sync, import, privacy integration, password CSV, and resource caches. Extension/password/autofill CRUD already have direct native adapters. RN theme controls also serve live NTP personalization. |
| Onboarding | `UI/Onboarding/{OnboardingOverlayView,OnboardingSteps,OnboardingPersonalize,OnboardingPairing,OnboardingSyncView}`; `UI/Tour/{ToolTourView,ToolTourModel}`; `Settings/Onboarding/{NativeOnboarding,OnboardingAdapter}`; `Settings/Tour/NativeToolTour` | Overlay and tour are native-only. Release enables first launch; Debug requires its onboarding flag (`OnboardingAdapter.swift:166`). JS still tracks sessions/tour, opens import, pins sites, and publishes context. RN personalization helpers remain live through NTP. |
| Import | `UI/Import/{ImportWindowView,ImportModel,ImportComponents,ImportData}`; `Settings/{NativeImportWindow,Adapters/ImportAdapter}`; `Store/Import` | Window pixels native. Adapter invokes JS discovery/unlock/run/cancel/Safari/HTML/Dia flows. Move application of imported workspace data, progress/error state, and coordination with import/engine services. |
| Internal pages | `UI/Pages/{HistoryPageView,BookmarksPageView,DownloadsPageView,ClearDataDialogView}`; `Settings/{Pages/PagesModule,NativeHistoryCatalog}` | Native-only page wrappers. JS still handles navigation, deletion, confirmation, bookmark groups/import/Arc restore/undo, downloads commands, themes, and URL classification. |
| Downloads | `UI/Downloads/{DownloadsListView,DownloadsPanelView,DownloadMagnetView}`; `Settings/Downloads/{DownloadsModule,NativeDownloadsPanel,NativeDownloadMagnet}` | Panel native in shell; list native when toolbar available. RN panel/rows remain fallback. JS still formats/feeds rows, routes menus/actions/open-when-done, measures placement, and triggers magnet state. |
| Extensions | `UI/SidePanel/ExtensionSidePanelView`; `UI/Panels/ExtensionDialogViews`; `Settings/{SidePanel/NativeExtensionSidePanel,Adapters/ExtensionsAdapter}`; `packages/solaracore/ios/ExtensionsModule.swift` | Side panel native by launch gate; install/pin dialogs native by toolbar gate. Popup keeps an RN pressable/animated frame around the engine view. JS still owns install/popup/side-panel lifecycle, sizing, selection, and state. |
| Site and prompts | `UI/SitePanel/SitePanelView`; `UI/Prompts/{PromptBodyView,DeviceChooserView}`; `UI/PaneOverlays/{PanePromptPage,PanePromptSpecs,PanePermissions,SelectionBarView}`; `Settings/{Services/NativeSiteControls,PaneOverlays/PanePrompts,SitePanel/SitePanelModule}` | Pooled prompts/site panels are native. Pooled site page commands use native `PageIssuer`; other bindings and `site.action` still bridge JS. Move JS engine offers, translation, selection search/copy, and compatibility policy. RN prompts/device/site/zoom bodies remain fallback. |
| Media | `UI/Media/{SidebarPlayerView,HoverPlayerCardView,ShareBarView,SharePickerView,CastPickerView,CliControlPillView}`; `Settings/Media/{NativeMedia,MediaModule}` | Players/pickers/control bodies native. JS still owns session/artwork replicas, source filtering/thumbnails, share/cast selection, playback/mute/PiP/dismiss actions, and share-bar layout animation. RN badge fills remain in retained callers. |
| Peek | `UI/Peek/{PeekOverlayView,PeekMotion}`; `Settings/WindowShell/NativePeek`; `Store/Peek` | Native peek when pooled; RN overlay otherwise (`ContentCard.tsx:351`). JS still publishes state and routes close/expand/hold/pinch. Move supported fallback pixels and remaining lifecycle policy. |
| Little Solara | `UI/LittleSolara/{LittleSolaraShellView,SmallBarView}`; `Settings/LittleSolara/NativeLittleSolara`; `Shell/Windows` | Native shell/bar wraps the main root. JS still composes content and command/download/extension overlays and handles open/expand/window targeting. This host does not start browser pane roots. |
| Live cards | `UI/Pages/{LiveCardsView,MeetingAlertFrameView}`; `UI/Sidebar/{SidebarLiveCard,SidebarMeetingCountdown}`; `Settings/Pages/MeetingAlertHost` | Calendar/alert card bodies native. RN live hover card is fallback when native hover kind is unavailable. JS still computes labels, join/related links, alerts, and placement. Standalone countdown/badge reachability is **unverified**; no consumer was found in scoped non-test source. |
| Live services | `Live/{Engine,Commands,Documents,Accounts,CalendarEngine,MeetingGroups,Meetings,GitHub,Rows}`; `Settings/Live/{NativeLiveEngine,NativeLiveEffects}` | Fetch jobs, secrets/calendar and live persistence are native. JS replicas remain; auth tabs, item-to-tab reuse, group/autogroup, cleanup, and join/open routing still run. Do not describe the live JSON replica as a second durable writer. |
| Store | `Store/{Store,Command,ChangeSet,StateJSON,Hydrate,SessionLoader,Tabs,Windows,Groups,Organize,Splits,PinMirror,PinShare,TabShare,TidyPins,TileFolders,PageReports}`; `packages/store/ios/{NativeStore,StoreModule,RNPageReports}.swift`; `Persistence/{Writer,SolaraDatabase,Importer}` | Native full ownership default. JS Zustand replica and revision guards remain. Wrapped workspace actions use native reducers; retained TS reducer bodies are largely fallback, while exported helpers can remain live. Remove unwrapped library/UI stores, replica consumers, and legacy migrations before deleting TS store code. |
| Sync | `Sync/{Scope,Files,HLC,Order,Canon,StateDecode,EditJournal,StoreAdapters,HostedAdapters,PinnedAdapters,Extensions,LedgerPasswords,PasswordLedger}`; `Store/{SyncPinsCommand,SyncPinned,SyncPinnedApply}`; `packages/sync/ios/SyncModule.swift` | JS sync orchestrator remains live when sync is enabled. Native transport/crypto/pairing and native pin apply do not replace JS adapter selection, cycles, sync.json, metadata, recovery, or merging. Native `syncScope` exists in CLI use; app ownership is **unverified** because inspected app adapters import SolaraSyncAdapter, not the SolaraSync library. |
| Lib | `UI/Services/{AppStartupPolicy,AppIntegrationPolicy,ScriptCommands,CliControlSync,MemoryTrimSchedule,SiteControlsLogic}`; `Settings/Services/{NativeAppStartup,NativeAppIntegration,NativeCliControl,NativeUserScripts,NativeMemoryTrim}`; `Shell/{Menus,Windows,Notifications,UserScripts}`; `Store/{ChromeTabs,NativeCaches,ProfileDataCleanup}` | JS window/menu/command/focus/engine/lifecycle integration remains live. Library sync/cache/migration services run even with native workspace. Native service files cover parts only; for example native memory trim still invokes JS compact. |

## Data ownership that still matters for 0.6.0

- `src/store/nativeStore.ts:253,288,400` forwards wrapped commands, applies revision commits, and guards writes to owned state. `store/browser.ts:204` disables several JS normalization/mirror observers under full ownership. This is real native ownership.
- `src/lib/persist.ts:395` starts bookmark/history/favicon services in the native branch too. `lib/bookmarks.ts:219,337,399` owns Chrome tree reconciliation, `bookmarks-cache.json`, and legacy bookmark retirement. `lib/history.ts:199,242,326` retains legacy history redaction/migration and tombstone handling.
- `src/lib/favicons.ts` still owns a JS cache and extraction/lookup work. `lib/launchLook.ts:31` still writes `launch-look.json` during final flush. Native image storage or a native history catalog does not eliminate these JS copies.
- `src/sync/engine.ts:526,679,749,2133` retains durable sync metadata, adapter construction, cycles, and startup. `sync/pinned.ts:70` delegates native apply under workspace ownership. Other data flows remain JS-coordinated.
- `src/components/settings/native/resources.ts`, page state, media state/artwork, extension state, sidebar state, and other local caches also remain. “The data layer is native” needs native owners or deletion of these replicas, not only a native session writer.

## RN registrations and native roots

| Item | Count | Evidence and lifetime |
| --- | --- | --- |
| Registration call sites | 3 | `src/main.tsx:72` registers `main`; `src/PaneRoot.tsx:35` registers `pane`; `src/nativeApi.tsx:22` registers a skew-screen `main`. |
| Normal registered module names | 2 | `main` and `pane`. `apps/browser/index.js:8` chooses skew startup instead of loading main when API versions differ. Skew registers only `main`; it is not a third module name or an extra normal root. |
| App-wide runtime | 1 factory/host | `AppDelegate.swift:16,24,28,32` initializes Expo/RN and supplies main/general root factories. Runtime initialization alone creates no visible root. |
| Browser window | 1 main + P + R pane roots | `Shell/Windows.swift:114,127` uses alternative Chrome/fallback window creation paths. `Settings/WindowShell/NativeWindowShell.swift:43,94,114` wraps the main root and starts pane hosting. P is currently shown native RN-overlay slots; R is hidden roots awaiting retirement. |
| Small window | 1 main | `Settings/LittleSolara/NativeLittleSolara.swift:18,58` wraps the existing main root. It does not start the browser pane-root host. |
| Pane/tab | At most 1 live root per tab ID per host | `Settings/PaneOverlays/NativePaneRoots.swift:73,108`; `UI/PaneOverlays/PaneRoots.swift:64`. Roots are lazy for shown overlay containers, not every background tab. Split/peek/pager transitions can expose extra tabs. |
| Retiring pane roots | Variable; 1-second grace | `UI/PaneOverlays/PaneRoots.swift:7,86,104`. Hide marks shown=false; re-show cancels retirement. Closed tabs end immediately. Teardown removes the view, observers, and invalidates content when supported. |
| Auxiliary settings/import | Normally 0 RN roots | `Shell/Windows.swift:437`; `Settings/NativeSettingsWindow.swift:79,96,104`; `Settings/NativeImportWindow.swift:16`. Native controllers win. Unhandled auxiliaries or an unavailable controller can fall back to 1 main root each. |
| Direct RCT allocations | 0 found in searched native scope | No direct `RCTRootView` or `RCTSurface` constructor found in `packages/*/ios` or `apps/browser/macos`. Expo `superView(withModuleName:initialProperties:)` creates the RN roots. `SolaraCorePixelGrid.mm` only detects RCTRootView. SwiftUI `rootView:` constructors are not RN roots. |

Source-derived steady state: one main root per browser/small window, plus the browser pane roots required by visible slots.
There is no fixed global per-window pane count. Actual P/R values are **unverified** without runtime measurement.
Native pane roots use moduleName `pane` and initial/app properties `windowId`, `tabId`, `shown`.
Main roots use moduleName `main` and `windowId`. Updates to `appProperties` do not create additional roots.
The skew code requests a settings-kind auxiliary; whether its RN error UI becomes visible is **unverified**, since native auxiliary interception may supply a controller.
The checked-in app uses Legacy RN: `Solara-macOS/Info.plist:127` and `macos/Podfile:10`; the Podfile permits an architecture override.
Main-window close removes its root/controller. Explicit RN invalidation is evident for pane roots; main-root unmount timing is **unverified** because framework lifetime also applies.

## Columns by roadmap version

The milestones are the ones in docs/roadmap.md (approved 2026-11-02). Each column leaves with one version.
Secondary work in a file moves with its own column: drawing inside a b or d file still has to go by 0.4.0.

| Version | Leaves | Files | Lines | Largest groups (lines in that column) |
| --- | --- | ---: | ---: | --- |
| 0.4.0: React Native draws nothing | a, drawing | 56 | 12,097 | Site and prompts 2,084; Top strip 1,754; Sidebar 1,161; Toolbar 1,108; Extensions 984 |
| 0.5.0: React Native decides nothing | b, behaviour | 194 | 24,435 | Store 5,504; Lib 5,086; Sidebar 2,375; Window layout 1,664; Page hosting 1,454 |
| 0.6.0: the data layer is native | c, data | 77 | 13,639 | Sync 5,716; Store 2,844; Lib 2,459; Settings 647; Onboarding 501 |
| 0.7.0: React Native off by default | d, glue, once nothing needs a root | 61 | 4,323 | Sidebar 1,020; Top strip 412; Toolbar 316; Lib 301; Page hosting 256 |
| 1.0.0: React Native deleted | everything left, plus the RN host, Expo modules, Metro, pods and patches outside apps/browser/src | 388 | 54,494 | see the 1.0.0 row below |

React Native roots left today: 3 AppRegistry registrations (`main`, `pane`, and the API-skew screen, which reuses `main`),
so 2 module names; one `main` root per browser or Little Solara window, plus a `pane` root for each pane whose overlay
is shown (hidden ones retire after 1 s). Settings and Import windows normally have none.

## Milestone removal order

Each cell lists the largest dependencies first. These are proposed work boundaries inferred from the inspected call paths.

| Milestone | Required moves | Exit evidence to collect later |
| --- | --- | --- |
| 0.4.0: draws nothing in RN | Port NTP extras and their shared onboarding/settings controls; port bookmarks bar; replace RN extension popup/frame and remaining supported fallback pixels. Cover error/skew, nonpooled peek/prompts, toolbar/find/site/download, and small-window paths. Transfer RN-driven layout/animation where native content still depends on it. Secondary a work inside b/d files also counts. | Every supported release surface and recovery path draws native pixels. Exercise unavailable-capability and handoff paths. Retained development fallbacks must be outside the milestone's supported release lane. |
| 0.5.0: decides nothing in RN | Move command/menu/window/focus/navigation orchestration; omnibox action/disposition/clipboard policy; import and settings RPC actions; sidebar/top-strip drag/selection/close/rename; live auth/meeting integration; media/extension/prompt/translation lifecycle. Retire TS workspace fallback reducers after native parity is demonstrated. | Native views and commands work with JS action/RPC handlers disabled. Native UI has no required JS decision round trip. |
| 0.6.0: data layer is native | Move the JS sync coordinator/adapters/durable metadata and legacy library reconciliation/migrations first. Remove JS bookmark/history/favicon/launch caches and unwrapped Zustand stores. Replace or delete UI/page/media/extension replicas. Keep native writer/ownership safeguards during the transition. | Full persistence, restart, import, sync, privacy deletion, and recovery work without JS data services. Native SolaraSync must be wired into the app, not merely present in the library. |
| 0.7.0: RN off by default | Remove mandatory `AppDelegate` main/pane root creation and `main.tsx` startup dependency. Give native app startup, window/menu binding, settings services, page props, and root handoff independent lifetimes. Default to no RN host/bridge; any compatibility switch must explicitly opt in. | Signed distribution starts, opens windows/tabs/settings, syncs, quits, and restores with no RN runtime or roots. UI switches being on is insufficient evidence. |
| 1.0.0: RN deleted | Delete retained RN roots, JS UI/decision/data fallbacks, JSON/RPC topics, test doubles, and skew plumbing. Remove Expo/RN native bindings, package dependencies, Metro/bundle phases, Pod integration, RN patches, and tests/harnesses that require RN. Audit package TS wrappers beyond this appendix before deleting shared pure TS. | Dependency/source/build audit finds no RN/Expo host or required bundle. Native-only release and recovery acceptance pass. Preserve engine/native APIs still used by the app. |

The 388-file appendix is not the full deletion boundary.
Outside it are `apps/browser/index.js`, macOS AppDelegate/Podfile/Xcode configuration, `packages/{settings,shell,solaracore}/src` wrappers, Expo module adapters, dependency manifests/locks, RN dependency patches, and build/test tooling.
These need a separate dependency closure check before 1.0.0. No package deletion safety claim is made here.

## Appendix: full file inventory

Paths are repository-relative. a = RN pixels; b = behavior; c = data; d = glue.
Each path appears once. Notes name secondary work where it materially affects removal.

| Path | Lines | Column | Note |
| --- | ---: | :---: | --- |
| `apps/browser/src/App.tsx` | 87 | d | Window/component placement; also b gates |
| `apps/browser/src/PaneRoot.tsx` | 36 | d | Pane root/context placement |
| `apps/browser/src/components/AreaBoundary.tsx` | 106 | a | RN error/reload UI; also b recovery |
| `apps/browser/src/components/AutoHideToolbar.tsx` | 268 | a | Fallback toolbar strip pixels; also b motion |
| `apps/browser/src/components/CliControlPill.tsx` | 61 | d | Native CLI-pill placement/feed |
| `apps/browser/src/components/CommandPanel.tsx` | 299 | b | Panel geometry/focus; also a frame |
| `apps/browser/src/components/ContentCard.tsx` | 728 | b | Page lifecycle/pooling; also a card/fallback pixels |
| `apps/browser/src/components/Downloads.tsx` | 654 | a | Fallback download pixels; also b menus/feeds |
| `apps/browser/src/components/EmptyCard.tsx` | 7 | d | Empty-card native composition |
| `apps/browser/src/components/FindBar.tsx` | 225 | a | Fallback find pixels; also b find/replace |
| `apps/browser/src/components/HoverSlot.tsx` | 30 | d | Transparent layout slots |
| `apps/browser/src/components/NativeAutoHide.tsx` | 50 | b | Toolbar reveal policy; also d feed |
| `apps/browser/src/components/NativeToolbar.tsx` | 316 | d | Native toolbar JSON model; also b click/menu policy |
| `apps/browser/src/components/NewTabPage.tsx` | 102 | b | Hero geometry/intro policy; also a extras composition |
| `apps/browser/src/components/PooledPageProps.tsx` | 28 | d | Pooled-page prop feed |
| `apps/browser/src/components/ProfileIndicator.tsx` | 118 | a | Fallback profile label; also b menu |
| `apps/browser/src/components/Sidebar.tsx` | 158 | a | Fallback sidebar chrome; also b routing |
| `apps/browser/src/components/Switch.tsx` | 87 | a | RN switch track/thumb |
| `apps/browser/src/components/Toolbar.tsx` | 452 | a | Fallback toolbar pixels; also b history/actions |
| `apps/browser/src/components/TooltipAbove.tsx` | 66 | a | RN tooltip label/motion |
| `apps/browser/src/components/WindowToolbar.tsx` | 49 | b | Toolbar routing; also c chrome cache |
| `apps/browser/src/components/bookmarks/BookmarkDialog.tsx` | 53 | b | Bookmark defaults and close handling |
| `apps/browser/src/components/bookmarks/EditBookmarkDialog.tsx` | 33 | b | Bookmark editor state and callbacks |
| `apps/browser/src/components/bookmarks/NativeBookmarkForms.tsx` | 100 | b | Bookmark editing rules; also d host |
| `apps/browser/src/components/bookmarks/actions.ts` | 114 | b | Bookmark menu/action routing |
| `apps/browser/src/components/bookmarks/edit.ts` | 45 | b | Bookmark edit/undo decisions |
| `apps/browser/src/components/downloadsPlacement.ts` | 43 | b | Download panel geometry rules |
| `apps/browser/src/components/extensions/ExtensionOverlays.tsx` | 382 | a | Live popup/fallback dialogs; also b lifecycle |
| `apps/browser/src/components/extensions/SidePanel.tsx` | 229 | a | Fallback panel chrome; also b sizing/lifecycle |
| `apps/browser/src/components/extensions/ToolbarExtensions.tsx` | 373 | a | Fallback extension buttons; also b native model |
| `apps/browser/src/components/extensions/actions.ts` | 50 | b | Extension menu/action routing |
| `apps/browser/src/components/extensions/bridge.ts` | 447 | b | Extension event/install/navigation policy |
| `apps/browser/src/components/extensions/searchEngines.ts` | 35 | b | Extension search-engine policy |
| `apps/browser/src/components/extensions/sidePanels.ts` | 67 | c | Side-panel state and selection |
| `apps/browser/src/components/extensions/state.ts` | 272 | c | Installed extensions/action state |
| `apps/browser/src/components/extensions/store.ts` | 96 | c | Web Store install/progress state |
| `apps/browser/src/components/glass.tsx` | 60 | d | Native glass placement |
| `apps/browser/src/components/import/apply.ts` | 315 | b | Import discovery/apply orchestration; also c |
| `apps/browser/src/components/import/arcTheme.ts` | 101 | c | Imported Arc theme conversion |
| `apps/browser/src/components/import/module.ts` | 14 | b | Import module capability gate |
| `apps/browser/src/components/layout/HistoryPopover.tsx` | 163 | a | Fallback history rows; also b navigation |
| `apps/browser/src/components/layout/NativeSplitToolbars.tsx` | 15 | d | Toolbar JSON/callback relay |
| `apps/browser/src/components/layout/NativeStripControls.tsx` | 77 | d | Native controls/glow JSON feed |
| `apps/browser/src/components/layout/NativeTopStrip.tsx` | 335 | d | Strip JSON feed; also b actions |
| `apps/browser/src/components/layout/PaneOverlays.tsx` | 84 | a | Fallback crash UI; also d status host |
| `apps/browser/src/components/layout/ProfileSwipe.tsx` | 113 | b | Profile swipe decisions; native tint placement |
| `apps/browser/src/components/layout/ShellBackdrop.tsx` | 42 | d | Native backdrop placement/feed |
| `apps/browser/src/components/layout/SidebarDock.tsx` | 487 | b | Dock/motion decisions; also a fallback surface |
| `apps/browser/src/components/layout/SplitChrome.tsx` | 344 | a | Fallback divider/drop/toast pixels; also b |
| `apps/browser/src/components/layout/SplitEmptyState.tsx` | 117 | a | Fallback pane search pixels; also b |
| `apps/browser/src/components/layout/SwipeOverlay.tsx` | 342 | a | Fallback swipe capsule/list; also b native policy |
| `apps/browser/src/components/layout/TopTabStrip.tsx` | 1754 | a | Fallback tab-strip pixels; also b drag/menu |
| `apps/browser/src/components/layout/WindowProfile.tsx` | 26 | d | Native profile/neighbour mirror |
| `apps/browser/src/components/layout/controls.tsx` | 406 | a | RN buttons/popovers; also b hover/motion |
| `apps/browser/src/components/layout/devExpose.ts` | 12 | d | Development exposure facade |
| `apps/browser/src/components/layout/dockMotion.ts` | 79 | b | Dock motion/edge/hit rules; also c |
| `apps/browser/src/components/layout/fileDrop.tsx` | 132 | b | Drop validation and tab placement |
| `apps/browser/src/components/layout/frozenPage.tsx` | 30 | a | RN frozen-page image/retry |
| `apps/browser/src/components/layout/geometry.ts` | 97 | b | Split sizing and toolbar geometry |
| `apps/browser/src/components/layout/history.ts` | 140 | b | Back/forward/history target rules; also c |
| `apps/browser/src/components/layout/measuredWidths.ts` | 11 | c | Measured-width cache |
| `apps/browser/src/components/layout/nativeDock.ts` | 77 | d | Native dock state/motion mirror |
| `apps/browser/src/components/layout/nativePaneOverlays.ts` | 221 | d | Pane overlay/hint JSON feeds |
| `apps/browser/src/components/layout/nativeSplitChrome.ts` | 156 | d | Split JSON feeds; also b toast callback |
| `apps/browser/src/components/layout/nativeTabDrag.ts` | 58 | b | Native drag event decisions |
| `apps/browser/src/components/layout/openFromPage.ts` | 48 | b | Page-created tab/window routing |
| `apps/browser/src/components/layout/pageState.ts` | 127 | c | Page facts and popover store; also b |
| `apps/browser/src/components/layout/paneFeed.ts` | 69 | c | Pane presence/status caches |
| `apps/browser/src/components/layout/peekHold.ts` | 28 | b | Peek hold/dismiss rules |
| `apps/browser/src/components/layout/pinHandoff.ts` | 125 | c | Frozen-page handoff state; also b |
| `apps/browser/src/components/layout/profilePager.ts` | 230 | b | Profile pager decisions; also c/d |
| `apps/browser/src/components/layout/shellLayout.ts` | 36 | d | Shell geometry feed |
| `apps/browser/src/components/layout/shellModal.ts` | 28 | b | Modal layer/interaction policy |
| `apps/browser/src/components/layout/splitActions.ts` | 101 | b | Split creation/drop/menu decisions |
| `apps/browser/src/components/layout/splitDrop.ts` | 43 | b | Split drop hit zones |
| `apps/browser/src/components/layout/stripFolderMenu.ts` | 19 | b | Strip folder menus |
| `apps/browser/src/components/layout/stripGroups.ts` | 226 | b | Strip grouping/drop/menu policy |
| `apps/browser/src/components/layout/stripReorder.ts` | 70 | b | RN reorder motion policy |
| `apps/browser/src/components/layout/swipeMotion.ts` | 33 | b | Swipe thresholds/selection math |
| `apps/browser/src/components/layout/tabDrag.ts` | 303 | b | Drag/drop lifecycle; also c/d |
| `apps/browser/src/components/layout/toasts.ts` | 23 | c | Toast/notice store; also b lifecycle |
| `apps/browser/src/components/layout/toolbarAutoHide.ts` | 81 | b | Toolbar visibility/scroll rules; also c |
| `apps/browser/src/components/layout/toolbarColors.ts` | 102 | b | Toolbar palette/motion policy |
| `apps/browser/src/components/layout/usePeek.ts` | 51 | b | Peek hover/motion decisions |
| `apps/browser/src/components/layout/useResizeDrag.ts` | 74 | b | Split resize interaction |
| `apps/browser/src/components/layout/windowDrop.ts` | 49 | b | Cross-window drag placement |
| `apps/browser/src/components/layout/windowLayout.ts` | 73 | b | Layout/address-bar selection; also c anchors |
| `apps/browser/src/components/littleSolara/LittleSolaraWindow.tsx` | 190 | b | Small-window composition; also d native bar |
| `apps/browser/src/components/littleSolara/SmallChrome.tsx` | 129 | a | RN label/progress fallback |
| `apps/browser/src/components/littleSolara/actions.ts` | 133 | b | Small-window open/expand routing |
| `apps/browser/src/components/live/CalendarPreview.tsx` | 123 | d | Native calendar-card placement/feed |
| `apps/browser/src/components/live/LiveItemCard.tsx` | 277 | a | Fallback live-card pixels; also b actions |
| `apps/browser/src/components/live/MeetingAlert.tsx` | 121 | b | Alert placement/join policy; also d feed |
| `apps/browser/src/components/live/MeetingCountdown.tsx` | 42 | a | RN countdown label |
| `apps/browser/src/components/live/NextMeetingBadge.tsx` | 64 | a | RN meeting badge/motion |
| `apps/browser/src/components/live/colors.ts` | 33 | d | Live badge palette |
| `apps/browser/src/components/media/CastPicker.tsx` | 92 | b | Cast target selection; also d host |
| `apps/browser/src/components/media/HoverPlayer.tsx` | 59 | d | Native hover-player placement/feed |
| `apps/browser/src/components/media/ShareBar.tsx` | 114 | b | Share controls; also d animated native placement |
| `apps/browser/src/components/media/SharePicker.tsx` | 196 | b | Screen-share selection; also d host |
| `apps/browser/src/components/media/SidebarPlayer.tsx` | 25 | d | Native sidebar-player tab selector |
| `apps/browser/src/components/media/TabBadges.tsx` | 55 | a | RN PiP/capture badge fills |
| `apps/browser/src/components/media/artwork.ts` | 51 | c | Artwork cache and loading |
| `apps/browser/src/components/media/cast.ts` | 80 | b | Cast target/menu policy |
| `apps/browser/src/components/media/nativeMedia.tsx` | 117 | b | Media control/action policy; also d JSON host |
| `apps/browser/src/components/media/pip.ts` | 44 | b | PiP open/close policy |
| `apps/browser/src/components/media/state.ts` | 189 | c | Media session and PiP stores |
| `apps/browser/src/components/media/tokens.ts` | 1 | d | Media token re-export |
| `apps/browser/src/components/nativeDownloadsPanel.ts` | 43 | d | Native download-panel state feed |
| `apps/browser/src/components/nativeHostProps.ts` | 69 | d | Native host JSON shapes |
| `apps/browser/src/components/ntp/CheckInBanner.tsx` | 109 | a | Live RN feedback banner; also b timing |
| `apps/browser/src/components/ntp/NativeNewTabHero.tsx` | 75 | d | Native hero host/feed; also b navigation callbacks |
| `apps/browser/src/components/ntp/Personalize.tsx` | 94 | a | Live RN NTP personalization |
| `apps/browser/src/components/ntp/Postcard.tsx` | 311 | a | Live RN release postcard/page |
| `apps/browser/src/components/ntp/index.tsx` | 30 | a | Live RN NTP extras composition |
| `apps/browser/src/components/ntp/newTabLayout.ts` | 21 | b | New Tab hero geometry |
| `apps/browser/src/components/ntp/releaseNotes.ts` | 117 | c | Release-note content/progress store; also b |
| `apps/browser/src/components/omnibox/NativeOmniboxBar.tsx` | 80 | d | Native bar host/focus relay; also b open callbacks |
| `apps/browser/src/components/omnibox/actions.ts` | 141 | b | Command candidate eligibility/titles |
| `apps/browser/src/components/omnibox/barState.ts` | 51 | b | Bar dismissal/focus policy; also c |
| `apps/browser/src/components/omnibox/devDriver.ts` | 55 | b | Omnibox driver/trace hooks |
| `apps/browser/src/components/omnibox/dropdownStart.ts` | 47 | b | Initial suggestion selection |
| `apps/browser/src/components/omnibox/extensions.ts` | 17 | c | Extension candidate projection |
| `apps/browser/src/components/omnibox/knownHosts.ts` | 30 | c | History host projection |
| `apps/browser/src/components/omnibox/nativeBar.tsx` | 207 | b | Open/action/menu decisions; also d feeds |
| `apps/browser/src/components/omnibox/newTabBar.ts` | 88 | b | New Tab bar open/close/target rules |
| `apps/browser/src/components/omnibox/open.ts` | 30 | b | Navigation/switch disposition |
| `apps/browser/src/components/omnibox/organizeActions.ts` | 154 | b | Organize-command eligibility |
| `apps/browser/src/components/omnibox/paste.ts` | 35 | b | Clipboard URL/menu decisions |
| `apps/browser/src/components/omnibox/profileBookmarks.ts` | 20 | c | Bookmark row projection |
| `apps/browser/src/components/omnibox/runBar.ts` | 79 | b | Command/extension dispatch |
| `apps/browser/src/components/omnibox/workspaceSources.ts` | 101 | b | Workspace feed selection; also d |
| `apps/browser/src/components/onboarding/OnboardingOverlay.tsx` | 20 | d | Native onboarding/tour placement |
| `apps/browser/src/components/onboarding/index.ts` | 3 | d | Onboarding export facade |
| `apps/browser/src/components/onboarding/personalize.tsx` | 131 | a | Live RN NTP layout/theme controls |
| `apps/browser/src/components/onboarding/sites.ts` | 66 | b | Onboarding site/pin selection |
| `apps/browser/src/components/onboarding/state.ts` | 397 | c | Onboarding document/session state; also b |
| `apps/browser/src/components/onboarding/tour/ToolTour.tsx` | 64 | d | Native tour state/anchor feed |
| `apps/browser/src/components/onboarding/tour/anchors.ts` | 47 | d | Native tour anchor feed |
| `apps/browser/src/components/onboarding/tour/state.ts` | 104 | c | Tour progress store; also b |
| `apps/browser/src/components/onboarding/ui.tsx` | 82 | a | Live RN NTP radio/colors |
| `apps/browser/src/components/overlayGates.ts` | 11 | d | Overlay owner gate helper |
| `apps/browser/src/components/pageEvents.ts` | 389 | b | Page-event handling/navigation; also c |
| `apps/browser/src/components/pages/ClearDataDialog.tsx` | 35 | b | Clear-data native invocation |
| `apps/browser/src/components/pages/InternalPage.tsx` | 38 | d | Native internal-page placement |
| `apps/browser/src/components/pages/NativeBookmarksPage.tsx` | 86 | b | Bookmark commands; also d page host |
| `apps/browser/src/components/pages/NativeDownloadsPage.tsx` | 37 | b | Download commands; also d page host |
| `apps/browser/src/components/pages/NativeHistoryPage.tsx` | 56 | b | History commands; also d page host |
| `apps/browser/src/components/pages/appUrls.ts` | 46 | b | App URL routing |
| `apps/browser/src/components/pages/devDrivers.ts` | 43 | b | Native page development driver |
| `apps/browser/src/components/pages/index.ts` | 3 | d | Internal-page export facade |
| `apps/browser/src/components/pages/internalUrls.ts` | 27 | b | Internal URL classification |
| `apps/browser/src/components/pages/nativePageTheme.ts` | 12 | d | Native page theme feed |
| `apps/browser/src/components/pages/urls.ts` | 28 | b | Internal URL/navigation routing |
| `apps/browser/src/components/peek/NativePeekMount.tsx` | 72 | b | Peek transitions; also d native state |
| `apps/browser/src/components/peek/PeekOverlay.tsx` | 239 | a | Fallback peek card/bar; also b interaction |
| `apps/browser/src/components/peek/actions.ts` | 136 | b | Peek open/close/expand routing |
| `apps/browser/src/components/peek/nativePeek.ts` | 56 | d | Native peek state feed |
| `apps/browser/src/components/peek/pinch.ts` | 17 | b | Pinch-to-peek interaction |
| `apps/browser/src/components/pooledPages.ts` | 149 | b | Pool plans/navigation reconciliation; also d |
| `apps/browser/src/components/primitives.tsx` | 150 | a | RN icons/images/buttons; also b hover |
| `apps/browser/src/components/profiles/CreateProfile.tsx` | 80 | b | Create-profile decisions; also d host |
| `apps/browser/src/components/profiles/ProfileDots.tsx` | 69 | a | Fallback RN profile-dot fills; also b switching |
| `apps/browser/src/components/profiles/icons.tsx` | 74 | a | RN profile glyph/tile fills |
| `apps/browser/src/components/settings/controls.tsx` | 311 | a | RN theme-picker controls |
| `apps/browser/src/components/settings/native/autofill.ts` | 36 | c | Autofill resource/cache facade; also b CRUD |
| `apps/browser/src/components/settings/native/extensions.ts` | 31 | b | Extension close/open/refresh routing; also d |
| `apps/browser/src/components/settings/native/import.ts` | 433 | b | Import RPC orchestration; also c progress |
| `apps/browser/src/components/settings/native/live.ts` | 28 | b | Live-folder/OAuth/window routing |
| `apps/browser/src/components/settings/native/onboarding.ts` | 94 | b | Onboarding action routing |
| `apps/browser/src/components/settings/native/passwords.ts` | 15 | b | Password CSV import routing; also d availability |
| `apps/browser/src/components/settings/native/privacy.ts` | 46 | b | Privacy clear-data operations |
| `apps/browser/src/components/settings/native/profiles.ts` | 97 | b | Profile settings operations |
| `apps/browser/src/components/settings/native/resources.ts` | 54 | c | Async resource cache/generation tracking |
| `apps/browser/src/components/settings/native/shortcuts.ts` | 11 | d | Shortcut topic mirror |
| `apps/browser/src/components/settings/native/sync.ts` | 114 | d | Sync status/action facade; also c |
| `apps/browser/src/components/settings/nativeSettings.ts` | 112 | b | JS topic/RPC server; also d feeds |
| `apps/browser/src/components/settings/searchMatch.ts` | 135 | b | Settings query matching/ranking |
| `apps/browser/src/components/settings/searchState.ts` | 30 | c | Settings search store |
| `apps/browser/src/components/settings/settingsIndex.ts` | 527 | c | Settings search catalog |
| `apps/browser/src/components/settings/sheet.ts` | 6 | d | Native settings sheet facade |
| `apps/browser/src/components/settings/windows.ts` | 43 | b | Settings/import window routing |
| `apps/browser/src/components/sidebar/AddressBar.tsx` | 256 | a | Fallback header pixels; also b/native model |
| `apps/browser/src/components/sidebar/FolderPanel.tsx` | 83 | d | Native folder panel lifecycle |
| `apps/browser/src/components/sidebar/FolderTile.tsx` | 41 | a | RN folder mosaic layout |
| `apps/browser/src/components/sidebar/GroupPanel.tsx` | 231 | a | Fallback group-search pixels; also b |
| `apps/browser/src/components/sidebar/HoverCard.tsx` | 366 | a | Fallback hover pixels; also b native routing |
| `apps/browser/src/components/sidebar/IconPicker.tsx` | 107 | b | Picker events; also d native host |
| `apps/browser/src/components/sidebar/NativeSidebar.tsx` | 392 | d | Sidebar JSON feed; also b actions |
| `apps/browser/src/components/sidebar/Overlays.tsx` | 26 | b | Overlay routing; also a child UI |
| `apps/browser/src/components/sidebar/ResizeHandle.tsx` | 26 | b | Resize gesture decisions |
| `apps/browser/src/components/sidebar/SearchTabs.tsx` | 81 | b | Search ranking; also d native feed |
| `apps/browser/src/components/sidebar/TabIcon.tsx` | 109 | a | RN favicon/engine-mark pixels |
| `apps/browser/src/components/sidebar/TabSwitcher.tsx` | 9 | d | Native switcher state feed |
| `apps/browser/src/components/sidebar/actions.ts` | 135 | b | Tab selection/rename decisions |
| `apps/browser/src/components/sidebar/cleanUpUpsell.ts` | 49 | b | Cleanup offer/dismiss rules |
| `apps/browser/src/components/sidebar/closeControl.ts` | 53 | b | Close/return-to-pin semantics |
| `apps/browser/src/components/sidebar/commands.ts` | 74 | b | Sidebar command/menu enablement |
| `apps/browser/src/components/sidebar/effects.ts` | 53 | b | Sidebar/live-service startup effects |
| `apps/browser/src/components/sidebar/entries.ts` | 130 | b | Sidebar ordering/group/split queries |
| `apps/browser/src/components/sidebar/fileDrop.tsx` | 21 | b | Sidebar drop target adapter |
| `apps/browser/src/components/sidebar/groupPanelRows.ts` | 40 | b | Group search/sort rules |
| `apps/browser/src/components/sidebar/hover.ts` | 153 | b | Hover intent/hold/dismiss rules |
| `apps/browser/src/components/sidebar/hoverAim.ts` | 20 | b | Hover-card pointer intent |
| `apps/browser/src/components/sidebar/hoverMotion.ts` | 109 | b | Hover placement/motion policy |
| `apps/browser/src/components/sidebar/liveMenus.ts` | 189 | b | Live-folder/calendar menus |
| `apps/browser/src/components/sidebar/menus.ts` | 436 | b | Tab/group/sidebar menus and cleanup |
| `apps/browser/src/components/sidebar/movePinned.ts` | 98 | b | Pin/unpin ordering rules |
| `apps/browser/src/components/sidebar/nativeDrag.ts` | 157 | b | Native drag callbacks/drop policy |
| `apps/browser/src/components/sidebar/nativeHoverCard.ts` | 296 | d | Native hover-card feed; also b kind choice |
| `apps/browser/src/components/sidebar/nativeLive.ts` | 101 | b | Live item actions; also d replica |
| `apps/browser/src/components/sidebar/nativeTabPickers.ts` | 114 | d | Native search/switcher JSON feed |
| `apps/browser/src/components/sidebar/pinnedOrder.ts` | 102 | b | Live/pinned ordering rules |
| `apps/browser/src/components/sidebar/state.ts` | 31 | c | Sidebar hover/rename/width store |
| `apps/browser/src/components/sidebar/switcher.ts` | 108 | b | Keyboard/mouse tab-switch policy |
| `apps/browser/src/components/sidebar/tidyPinsUi.ts` | 25 | b | Tidy/undo command routing |
| `apps/browser/src/components/sidebar/tileFolderUi.ts` | 82 | b | Tile-folder menu/open/rename rules |
| `apps/browser/src/components/sidebar/tokens.ts` | 126 | d | Sidebar palette/size tokens |
| `apps/browser/src/components/site/Autofill.tsx` | 48 | a | Fallback autofill text/card details |
| `apps/browser/src/components/site/DeveloperButtons.tsx` | 64 | a | Fallback developer buttons |
| `apps/browser/src/components/site/DeveloperStripes.tsx` | 22 | a | RN developer stripe image |
| `apps/browser/src/components/site/DeveloperUrlInput.tsx` | 50 | a | RN developer URL field; also b editing |
| `apps/browser/src/components/site/DeviceChooser.tsx` | 261 | a | Fallback chooser pixels; also b selection |
| `apps/browser/src/components/site/EnginePrompt.tsx` | 60 | a | Fallback engine-offer pixels; also b |
| `apps/browser/src/components/site/NativePromptBody.tsx` | 91 | d | Native prompt placement/size feed |
| `apps/browser/src/components/site/NativeSiteControls.tsx` | 180 | b | Site-panel decisions; also d native host |
| `apps/browser/src/components/site/Prompts.tsx` | 447 | a | Fallback prompt pixels; also b answers |
| `apps/browser/src/components/site/SelectionPopover.tsx` | 139 | a | Fallback selection bar; also b search/copy |
| `apps/browser/src/components/site/SiteControls.tsx` | 455 | a | Fallback site panel; also b policy |
| `apps/browser/src/components/site/SiteControlsParts.tsx` | 259 | a | RN site-panel tiles/rows |
| `apps/browser/src/components/site/SiteExtensions.tsx` | 65 | a | Fallback extension grid; also b menus |
| `apps/browser/src/components/site/TranslateControls.tsx` | 105 | a | Fallback translate rows/buttons; also b |
| `apps/browser/src/components/site/ZoomControls.tsx` | 109 | a | Fallback zoom pixels; also b native events |
| `apps/browser/src/components/site/developerMode.ts` | 111 | b | Developer URL/reload policy; also c |
| `apps/browser/src/components/site/pageTranslator.ts` | 201 | b | Page translation execution |
| `apps/browser/src/components/site/permissions.ts` | 139 | b | Permission request/answer rules |
| `apps/browser/src/components/site/promptGuard.ts` | 41 | b | Prompt lifetime guards |
| `apps/browser/src/components/site/selection.ts` | 249 | b | Selection search/copy/open policy; also c |
| `apps/browser/src/components/site/share.ts` | 12 | b | Native share command routing |
| `apps/browser/src/components/site/translate.ts` | 235 | b | Translation state/language policy; also c |
| `apps/browser/src/legacy.ts` | 51 | c | Legacy URL/key migration |
| `apps/browser/src/lib/actions.ts` | 203 | b | Window/tab/profile action routing |
| `apps/browser/src/lib/afterFirstWindow.ts` | 31 | b | First-window task scheduling |
| `apps/browser/src/lib/appIcon.ts` | 1 | d | Bundled app icon reference |
| `apps/browser/src/lib/appIntegration.ts` | 103 | b | Native app/notification event decisions |
| `apps/browser/src/lib/bookmarkGroups.ts` | 88 | b | Bookmark-folder sidebar restoration |
| `apps/browser/src/lib/bookmarks.ts` | 489 | c | Chrome bookmark sync and migration |
| `apps/browser/src/lib/chromeTabs.ts` | 157 | c | Fallback Chrome tab synchronization; also b |
| `apps/browser/src/lib/cliControl.ts` | 71 | b | CLI install/stop decisions; also c mirror |
| `apps/browser/src/lib/closeAnimated.ts` | 29 | b | Animated window-close scheduling |
| `apps/browser/src/lib/closeSnapshots.ts` | 17 | c | Window close snapshot cache |
| `apps/browser/src/lib/closeWindowDialog.ts` | 24 | b | Close confirmation decisions |
| `apps/browser/src/lib/commandCatalog.ts` | 242 | b | Command metadata/eligibility |
| `apps/browser/src/lib/commandShortcuts.ts` | 69 | b | Shortcut/menu resolution; also c |
| `apps/browser/src/lib/commands.ts` | 406 | b | Main command dispatch |
| `apps/browser/src/lib/defaultBrowserCheckIn.ts` | 43 | b | Feedback check-in eligibility |
| `apps/browser/src/lib/devHarness.ts` | 120 | b | Development command dispatch |
| `apps/browser/src/lib/developerMode.ts` | 57 | b | Developer-host policy |
| `apps/browser/src/lib/earlyNavigate.ts` | 27 | b | Early-navigation handoff policy |
| `apps/browser/src/lib/engineSignIn.ts` | 41 | b | WebKit sign-in transfer decisions |
| `apps/browser/src/lib/engines.ts` | 201 | b | Engine offer/switch/history policy; also c |
| `apps/browser/src/lib/favicons.ts` | 484 | c | Favicon cache/lookup/migration |
| `apps/browser/src/lib/focusClaims.ts` | 77 | b | Focus generation/claim policy |
| `apps/browser/src/lib/focusHandoff.ts` | 61 | b | Command focus settlement |
| `apps/browser/src/lib/history.ts` | 375 | c | History sync and legacy redaction |
| `apps/browser/src/lib/hoverShift.ts` | 151 | b | Development React layout inspection |
| `apps/browser/src/lib/jsErrors.ts` | 81 | c | JS error recording; also b fatal policy |
| `apps/browser/src/lib/killSwitches.ts` | 111 | c | Cached switch configuration; also b defaults |
| `apps/browser/src/lib/launchBackdrop.ts` | 21 | d | Native launch-backdrop projection |
| `apps/browser/src/lib/launchLook.ts` | 112 | c | Launch appearance cache; also b fallback |
| `apps/browser/src/lib/layoutWatch.ts` | 99 | b | Layout diagnostics; also c report |
| `apps/browser/src/lib/linkRoutes.ts` | 18 | b | External-link profile/adoption routing |
| `apps/browser/src/lib/livePage.ts` | 40 | b | Live WebView command targeting |
| `apps/browser/src/lib/memoryTrim.ts` | 45 | b | Memory compaction policy |
| `apps/browser/src/lib/native.ts` | 293 | b | Window/menu/native event decisions; also d |
| `apps/browser/src/lib/nativeEvents.ts` | 142 | d | Native report batching/relay |
| `apps/browser/src/lib/notifications.ts` | 20 | b | Notification event routing |
| `apps/browser/src/lib/opaqueCard.ts` | 15 | d | Native card color projection |
| `apps/browser/src/lib/pageHandoff.ts` | 2 | d | Handoff completion helper |
| `apps/browser/src/lib/pagesPool.ts` | 6 | d | Native pool/overlay owner gates |
| `apps/browser/src/lib/pendingUpdate.ts` | 39 | c | Pending-update mirror; also b install |
| `apps/browser/src/lib/perfMarks.ts` | 216 | b | Journey sampling; also c counters |
| `apps/browser/src/lib/perfProbe.ts` | 521 | b | React/bridge instrumentation; also c |
| `apps/browser/src/lib/persist.ts` | 423 | c | Persistence/bootstrap/migration; also b |
| `apps/browser/src/lib/persistLatch.ts` | 8 | c | Persistence refusal latch |
| `apps/browser/src/lib/preload.ts` | 40 | b | Engine prewarm policy |
| `apps/browser/src/lib/productName.ts` | 33 | d | Native product metadata/constants |
| `apps/browser/src/lib/profileData.ts` | 44 | c | Deleted-profile data cleanup |
| `apps/browser/src/lib/profileTheme.ts` | 341 | b | Profile appearance selection/math; also c schema |
| `apps/browser/src/lib/profileThemeActions.ts` | 13 | b | Profile-theme action routing |
| `apps/browser/src/lib/scriptUrls.ts` | 10 | b | JavaScript URL admission |
| `apps/browser/src/lib/shortcuts.ts` | 115 | b | Shortcut parsing/conflict resolution |
| `apps/browser/src/lib/signInCookies.ts` | 24 | c | Cookie transfer filtering |
| `apps/browser/src/lib/siteIcons.ts` | 37 | d | Bundled site icon lookup |
| `apps/browser/src/lib/slowTimers.ts` | 111 | b | Slow-job scheduling |
| `apps/browser/src/lib/tabLifecycle.ts` | 469 | b | Discard/freeze/battery policy; also c state |
| `apps/browser/src/lib/tabPages.ts` | 66 | b | Page transfer/launch claim decisions |
| `apps/browser/src/lib/tabPictures.ts` | 61 | c | Tab screenshot cache |
| `apps/browser/src/lib/tabReveal.ts` | 61 | b | Tab-reveal eligibility |
| `apps/browser/src/lib/theme.ts` | 311 | b | Appearance/palette resolution; also d tokens |
| `apps/browser/src/lib/tileTheme.ts` | 28 | d | Theme token projection |
| `apps/browser/src/lib/timeAgo.ts` | 16 | d | Relative-time display formatter |
| `apps/browser/src/lib/webviews.ts` | 34 | c | WebView handle registry |
| `apps/browser/src/lib/windowClose.ts` | 72 | b | Window-close decision sequencing |
| `apps/browser/src/lib/windowOpenOrder.ts` | 15 | b | Window launch ordering |
| `apps/browser/src/lib/windowSync.ts` | 111 | b | Window open/close/fullscreen policy; also d |
| `apps/browser/src/lib/windowTint.ts` | 55 | b | Window-tint tracking/motion policy |
| `apps/browser/src/live/alerts.ts` | 37 | b | Meeting join/dismiss/window selection |
| `apps/browser/src/live/calendar.ts` | 59 | d | Native calendar replica; also b clock timer |
| `apps/browser/src/live/engine.ts` | 112 | b | Live tab integration/cleanup decisions |
| `apps/browser/src/live/github.ts` | 31 | b | GitHub status/tone derivation |
| `apps/browser/src/live/googleAuth.ts` | 49 | b | OAuth tab/window lifecycle |
| `apps/browser/src/live/index.ts` | 9 | b | Starts auth/grouping/cleanup observers |
| `apps/browser/src/live/meetingGroups.ts` | 120 | b | Meeting tab/group/autogroup decisions |
| `apps/browser/src/live/meetings.ts` | 182 | b | Meeting URL/event/link matching |
| `apps/browser/src/live/rows.ts` | 51 | b | Live row/stack/pagination policy |
| `apps/browser/src/live/sources.ts` | 11 | b | Live source/icon fallback policy |
| `apps/browser/src/live/store.ts` | 157 | d | Native live JSON replica/command facade |
| `apps/browser/src/live/types.ts` | 75 | c | Live source/item data types |
| `apps/browser/src/main.tsx` | 74 | b | Service boot; main/pane registration |
| `apps/browser/src/nativeApi.tsx` | 43 | a | Alternate skew-screen pixels; also b version gate |
| `apps/browser/src/react-native-macos.d.ts` | 10 | d | RN type declarations; no runtime |
| `apps/browser/src/store/bookmarks.ts` | 275 | c | Bookmark tree model and edits; also b |
| `apps/browser/src/store/browser.ts` | 250 | c | Zustand assembly/replica; also b fallback |
| `apps/browser/src/store/changes.ts` | 22 | c | Store subscription comparison |
| `apps/browser/src/store/closedTogether.ts` | 25 | b | Reopen eligibility and order |
| `apps/browser/src/store/closingWindowRestore.ts` | 79 | c | Close snapshot remapping/undo |
| `apps/browser/src/store/closingWindows.ts` | 14 | c | Closing-window set; also d command forwarding |
| `apps/browser/src/store/draftGroups.ts` | 89 | b | Draft admission/dedupe/placement; also c |
| `apps/browser/src/store/drops.ts` | 175 | b | Drop and selection rules; also c |
| `apps/browser/src/store/engines.ts` | 153 | b | Engine choice and visit debounce; also c |
| `apps/browser/src/store/groupNames.ts` | 99 | b | Automatic group naming |
| `apps/browser/src/store/groups.ts` | 419 | b | Group creation/nesting/close rules; also c |
| `apps/browser/src/store/history.ts` | 70 | c | History state and migration |
| `apps/browser/src/store/hooks.ts` | 85 | c | Zustand/window context selectors |
| `apps/browser/src/store/launchTab.ts` | 22 | b | Early-launch tab eligibility |
| `apps/browser/src/store/liveTabs.ts` | 308 | b | Chrome reconciliation policy; also c |
| `apps/browser/src/store/model.ts` | 213 | c | State queries/types; also b selection |
| `apps/browser/src/store/nativeStore.ts` | 458 | c | Native-store replica/guards; also d dispatch |
| `apps/browser/src/store/nativeWorkspace.ts` | 169 | d | Workspace patches/effects relay |
| `apps/browser/src/store/newTabBar.ts` | 40 | b | Empty-window command-bar policy |
| `apps/browser/src/store/openers.ts` | 100 | b | New-tab placement and successor rules |
| `apps/browser/src/store/organize.ts` | 1039 | b | Selection/pin/group/cleanup rules; also c |
| `apps/browser/src/store/pageKeys.ts` | 32 | c | Page identity keys |
| `apps/browser/src/store/pageProgress.ts` | 29 | c | Page progress replica |
| `apps/browser/src/store/pageSession.ts` | 15 | c | Per-page session tracking |
| `apps/browser/src/store/parkedPins.ts` | 146 | c | Pin snapshot/adoption; also b admission |
| `apps/browser/src/store/peek.ts` | 108 | b | Peek lifecycle; also c |
| `apps/browser/src/store/pinHomes.ts` | 28 | b | Pinned-home policy |
| `apps/browser/src/store/pinMirror.ts` | 397 | b | Cross-window pin rules; also c |
| `apps/browser/src/store/pinOrderChoices.ts` | 61 | c | Pinned-order choice records |
| `apps/browser/src/store/pinShare.ts` | 260 | b | Pinned-page sharing/handoff; also c |
| `apps/browser/src/store/pinnedArea.ts` | 122 | c | Pinned-area state transforms |
| `apps/browser/src/store/profiles.ts` | 231 | c | Profile identity/data lifecycle; also b |
| `apps/browser/src/store/safeLibraryEdits.ts` | 29 | c | Bookmark edit safety state |
| `apps/browser/src/store/settings.ts` | 311 | c | Settings schema/defaults; also b policy |
| `apps/browser/src/store/small.ts` | 39 | b | Little Solara targeting; also c |
| `apps/browser/src/store/splits.ts` | 342 | b | Pane creation/focus/layout rules; also c |
| `apps/browser/src/store/structure.ts` | 36 | c | Workspace structure transforms |
| `apps/browser/src/store/syncOrigin.ts` | 22 | c | Sync-origin transaction marker |
| `apps/browser/src/store/tabShare.ts` | 354 | b | Shared-tab rules; also c |
| `apps/browser/src/store/tabWatch.ts` | 86 | c | Tab state subscriptions |
| `apps/browser/src/store/tabs.ts` | 536 | b | Tab open/close/navigation rules; also c |
| `apps/browser/src/store/tidyPins.ts` | 153 | b | Pinned grouping policy |
| `apps/browser/src/store/tileFolders.ts` | 171 | b | Tile-folder semantics; also c |
| `apps/browser/src/store/transaction.ts` | 50 | c | State transaction boundaries |
| `apps/browser/src/store/types.ts` | 208 | c | Browser-state types; no runtime |
| `apps/browser/src/store/ui.ts` | 135 | b | Panel/focus/download behavior; also c |
| `apps/browser/src/store/windows.ts` | 512 | b | Window lifecycle and restore rules; also c |
| `apps/browser/src/sync/adapters.ts` | 649 | c | Settings/profile/library sync adapters |
| `apps/browser/src/sync/commandJournal.ts` | 58 | c | Command journal encoding/replay |
| `apps/browser/src/sync/editJournal.ts` | 121 | c | Durable edit journal |
| `apps/browser/src/sync/engine.ts` | 2186 | c | Sync orchestration/persistence; also b |
| `apps/browser/src/sync/extensions.ts` | 110 | c | Extension sync reconciliation |
| `apps/browser/src/sync/fixtures/pinned-v0.2.38.ts` | 184 | c | Historical pin fixture; non-test filename |
| `apps/browser/src/sync/fixtures/pinned-v0.2.40.ts` | 507 | c | Historical pin fixture; non-test filename |
| `apps/browser/src/sync/journalHost.ts` | 194 | c | Journal state host |
| `apps/browser/src/sync/ledgerPasswords.ts` | 313 | c | Password-ledger sync adapter |
| `apps/browser/src/sync/menu.ts` | 33 | b | Sync device/tab menu choices |
| `apps/browser/src/sync/notes.ts` | 14 | c | Sync note/state records |
| `apps/browser/src/sync/pairingBootstrap.ts` | 109 | c | Pairing document bootstrap |
| `apps/browser/src/sync/pairingNative.ts` | 54 | b | Pairing startup/retry coordination; also c |
| `apps/browser/src/sync/passwordLedger.ts` | 178 | c | Password-ledger state |
| `apps/browser/src/sync/pinned.ts` | 931 | c | Pin extraction/merge; native apply |
| `apps/browser/src/sync/readable.ts` | 33 | c | Readable sync state serialization |
| `apps/browser/src/sync/redesignSwitch.ts` | 1 | d | Native sync-launch gate mirror |
| `apps/browser/src/sync/stateDeltas.ts` | 129 | c | Sync delta generation/replay |

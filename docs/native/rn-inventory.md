# React Native removal inventory

Release-path findings: `209d9238fde4ce41ee612fe2d99851ab69a177f3` on main (0.3.4), audited 2026-11-13.
Source counts and deletion audit: HEAD `16842518b5dd59bbf148713b51e3f284c38e5655`, recounted 2026-11-14 after the extensions, Downloads, toolbar backdrop and no-shell group ports.

Scope: 401 non-test `.ts`/`.tsx` files under `apps/browser/src`. Total: 51,881 lines.
Excluded: `*.test.*` and 8 test doubles in `src/test-native/` (1,044 lines).
Suffix filtering alone finds 409 files and 52,925 lines. The test doubles explain the difference.
The two `sync/fixtures/pinned-v0.2.*.ts` files remain included. They do not use test filenames.
Counts use `wc -l` on every included file. They include blank lines and declarations.
Source-budget tables are derived from the appendix; every included path and line count was checked against the files.
The inventory is a source audit. Targeted unit and hidden-instance checks do not validate unrelated rows.

Each file has one primary column. Mixed files name secondary columns in the appendix.
The choice follows the file's dominant responsibility. Whole-file lines go to that column.
The earlier cleanup removed five unused files / 223 lines. This cutover also removes the unconsumed
`site/DeveloperUrlInput.tsx` after its parent toolbar body was replaced; shared layout controls now draw nothing.
Downloads skin/button/motion, ToolbarBackdrop and the no-shell GroupPanel now host Swift drawing; their adapters remain.
Unread badges, tab-number hints, config-file controls and hooks landed in Swift; they add no RN drawing files.

An a count includes retained fallback drawing code. It is not a count of live release UI.
A b/d file can contain some a work. For example, `ContentCard.tsx` has drawing and page lifecycle code.
Types, constants, and export facades follow their owning data or glue module.
Transparent layout containers around native content count as glue, unless interaction policy dominates.
Theme resolution, ranking, geometry, and gesture thresholds count as behavior. They do not draw pixels themselves.

| Column | Primary responsibility | Files | Lines |
| --- | --- | ---: | ---: |
| a | Draws RN pixels | 22 | 5,003 |
| b | Decides behavior | 234 | 28,651 |
| c | Holds data | 75 | 13,406 |
| d | Glue | 70 | 4,821 |
| Total | All included files | 401 | 51,881 |

## Findings that set the order

1. Targeted native hosts wired in this follow-up: sad-tab, selection, swipe, frozen-page and NTP Personalize, feedback, release notes, favicons and area recovery. The appendix reclassifies their former drawing adapters.
2. The New Tab feedback check-in and release postcard/page now use Swift hosts alongside Personalize. Their RN drawing bodies are deleted; JS retains state and actions. The release-note catalog still has no matching 0.3.4 entry, so the notices driver queues the existing 1.0 fixture. Little Solara card fill and clipping now have a native page container (VM verification pending); unrelated fallback surfaces retain RN pixels; frozen-page snapshots/washes now use the native view. The component list below separates these from native-shadowed fallbacks.
3. Bookmarks bar, bookmark dialogs, extension popup frames in browser and Little Solara windows, install/pin sheets, extension menus and side-panel containers draw natively. Their JS bridges still decide actions and project state. RN extension-button and badge drawing is deleted; the toolbar model remains behavior.
4. Native controls still depend on JS actions, menus, focus, navigation, import, media, and window orchestration.
5. Native workspace ownership is already the default. It does not remove JS sync, library reconciliation, caches, or migration work.
6. A native window shell still wraps an RN main root. Browser pane roots add more RN roots. Native UI switches do not disable the RN runtime.

The 0.4.2 tabs/windows command port adds Swift ownership of menu, shortcut and direct-command routing through
`WorkspaceMenuCommand` and `NativeWorkspaceCommands`. Existing store reducers remain canonical, including `newTab`.
JavaScript command branches remain the workspace-ownership fallback; the new handler-disabled driver and Swift tests
require VM verification. Other command groups, menu-state projection and remaining window lifecycle feeds still count
as column b behavior; this partial port does not complete the 0.4.2 command row or change source totals.

The 0.4.6 drag, folder and group port (S1 99c6c03f to S4 180ffd7e) has Swift decide a tab drag's preview,
pictures, haptic and glow, file and link drops on the sidebar and native-layout strip, group collapse, close, tuck
and menu, and the tile-folder panel and menus, whenever the native store owns the workspace. The TypeScript
branches remain the fallback when the store never opened or stood down (frozen); safe mode is decided in Swift too (S6a
58bc7ecb). Only the folder panel's open state is mirrored back
(`folderPanel.state`). The cleanup (S5) found one never-called export, `folderTitle`; no decision branch was
provably dead, so columns are unchanged; counts stay those of the dated audit.

These are source findings. Runtime reachability, visual parity, and root counts in an actual release are **unverified** by this source inventory; its release-path findings remain the 2026-11-13 audit.
Native counterparts below prove that code exists. They do not establish complete behavioral parity.

The favicon and area-recovery follow-up was checked in a hidden Debug instance: Little Solara, both swipe drivers, exhausted window/sidebar recovery (themed/plain), quiet panes, keyboard and AX Reload. Matched 2× captures retain native icon dimensions and initial placement; the plain recovery crop is pixel-exact. Real trackpad feel and VoiceOver speech remain owner checks.

## Release lanes and ownership gates

| Gate | Checked source | Meaning |
| --- | --- | --- |
| Shipped UI defaults | `native/SolaraKit/Sources/SolaraModel/LaunchSwitches.swift:28`, `:71`, `:199` | Native shell, top strip, bookmarks bar, shell panes, pages pool, and main-on-top default on. Extension side panels are now native-only. Distribution ignores their environment and stored overrides. Distribution is signing-derived or `SOLARA_RELEASE_LAUNCH=1`; it is not every Xcode Release build. |
| Safe mode | Same file, `:159`, `:223`; `packages/store/ios/NativeStore.swift:144` | Safe mode keeps native UI. Full in-memory ownership can remain native while persistence narrows to settings/downloads. It holds sync and unsafe operations. |
| Workspace ownership | `packages/store/ios/NativeStore.swift:150`; `src/store/nativeStore.ts:59`, `:70` | A native store that opens always owns the whole workspace; the `SOLARA_NATIVE_SCOPE` switch is gone (0.4.6). `nativeOwnsWorkspace()` is true while the native store is active and hasn't stood down. |
| Native settings, toolbar, pages, hero | `packages/store/ios/NativeStore.swift:173`; `packages/settings/ios/{NativeSettingsWindow,Toolbar/ToolbarModule,Pages/PagesModule,NewTab/NewTabModule}.swift` | Availability follows the opened native settings handle. These are release paths, not debug-only implementations. A store that never opens stops the launch at the native `StoreUnavailableWindow` (`packages/settings/ios/StoreUnavailableWindow.swift`) before React Native starts, so Settings' `unavailableController` is no longer reached (S7c removes it). |
| Hosted capabilities | `packages/settings/src/hosted.tsx:19`; `packages/settings/ios/Hosted/{HostedViews,HostedModule}.swift` | `hostedKinds()` reports capability names, not mounted views. Missing module/errors yield an empty list. Some capabilities deliberately have nil view factories. |
| Top strip | `src/components/layout/NativeTopStrip.tsx:32`; `NativeStripControls.tsx:11`; `packages/settings/ios/TopStrip/NativeTopStrip.swift:107` | `nativeTopStripEnabled`, `nativeStripPeekEnabled`, and `nativeStripControlsEnabled` cache hosted-kind membership. RN fallbacks remain. Registration is asynchronous; first-read timing is **unverified** without a launch. |
| Full sidebar column | `src/components/sidebar/NativeSidebar.tsx:57`; `src/components/Sidebar.tsx:37` | Needs hosted sidebar shell, active native window, and native-owned profile pager. Sidebar address mode also needs native omnibox/address-bar capability. RN header/footer/dots remain fallback. |
| Actual native page pool | `packages/settings/ios/TabPool/TabPoolHost.swift:13`; `src/lib/pagesPool.ts:3` | Needs native split configuration, pane-root factory, opened store, ownership at launch, and `SOLARA_TAB_POOL != 0`. JS also checks shell/pane/pool availability. `windowPagesPoolActive()` alone is only a configuration flag. |
| Pane handoff | `src/components/ContentCard.tsx:419`, `:588` | The main-root fallback remains until the pane root reports a real layout. Pooled native prompts suppress duplicate JS-hosted native prompt adapters. |
| Persistence | `src/lib/persist.ts` | The native writer persists workspace, settings and downloads. JS attaches a replica and starts derived services. A missing, unowned or unreadable native workspace ends in `savesNothing`: the persistence latch and the store-unavailable window; no TypeScript session loader or save loop remains. |
| Sync redesign | `src/sync/redesignSwitch.ts`; `packages/store/ios/StoreModule.swift:66`; `LaunchSwitches.swift:70` | Default off. Development override requires an isolated data directory. Journal/password redesign code is not evidence that the shipped sync path is native. |

## Module totals

All numbers are whole-file `wc -l` counts. Group membership follows the path, with layout files split by surface.
The root `legacy.ts` is Bootstrap. Generic library helpers stay in Lib.
The NTP adapters feed native Personalize, check-in and release-note hosts; transparent composition and tour anchors count as glue.

| Group | Files | a lines | b lines | c lines | d lines | Total lines |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| Bootstrap | 6 | 43 | 78 | 51 | 157 | 329 |
| Shared UI | 7 | 296 | 163 | 0 | 126 | 585 |
| Window layout | 21 | 0 | 1,805 | 32 | 232 | 2,069 |
| Page hosting | 15 | 0 | 1,748 | 321 | 293 | 2,362 |
| Split panes | 9 | 461 | 315 | 23 | 171 | 970 |
| Sidebar | 38 | 675 | 2,459 | 31 | 1,147 | 4,312 |
| Top strip | 6 | 1,755 | 315 | 0 | 446 | 2,516 |
| Toolbar | 9 | 500 | 369 | 0 | 390 | 1,259 |
| Omnibox | 16 | 0 | 1,287 | 67 | 80 | 1,434 |
| New Tab | 8 | 0 | 187 | 133 | 229 | 549 |
| Bookmarks | 11 | 0 | 485 | 0 | 148 | 633 |
| Profiles | 4 | 192 | 82 | 0 | 0 | 274 |
| Settings | 17 | 311 | 1,043 | 693 | 130 | 2,177 |
| Onboarding | 7 | 0 | 66 | 501 | 134 | 701 |
| Import | 3 | 0 | 365 | 101 | 0 | 466 |
| Internal pages | 11 | 0 | 372 | 0 | 53 | 425 |
| Downloads | 3 | 0 | 404 | 0 | 54 | 458 |
| Extensions | 10 | 0 | 1,459 | 108 | 0 | 1,567 |
| Site and prompts | 21 | 70 | 1,761 | 0 | 115 | 1,946 |
| Media | 13 | 55 | 700 | 240 | 121 | 1,116 |
| Peek | 5 | 239 | 225 | 0 | 56 | 520 |
| Little Solara | 3 | 129 | 324 | 0 | 0 | 453 |
| Live cards | 4 | 277 | 244 | 0 | 33 | 554 |
| Live services | 11 | 0 | 551 | 75 | 206 | 832 |
| Store | 49 | 0 | 5,579 | 2,920 | 176 | 8,675 |
| Sync | 18 | 0 | 87 | 6,050 | 1 | 6,138 |
| Lib | 76 | 0 | 6,178 | 2,060 | 323 | 8,561 |
| Total | 401 | 5,003 | 28,651 | 13,406 | 4,821 | 51,881 |

## 0.4.0: components still drawing on native-default paths

Here “normal” means matching native API, opened native store, full ownership, shipped capabilities and default launch
switches. It includes normal user actions after launch: opening Little Solara, sharing a pin across windows, selecting
text, swiping history and showing a due check-in. It does not mean every component appears on the first frame.
Recovery, unavailable capabilities and explicit development/pool overrides are distinguished below.
These are static call-path findings, not runtime observations.

Paths in this section: `C/` = `apps/browser/src/components/`; `UI/` = `native/SolaraKit/Sources/SolaraUI/`;
`Settings/` = `packages/settings/ios/`. Native filenames end in `.swift` unless shown otherwise.
Sizes are whole-file lines, including behavior and glue, not measured pixel code. Shared helpers are listed once.

### Components and targeted native-host ports, grouped by the 0.4.0 roadmap rows

| Roadmap row | RN components and when they draw | Native counterpart already present | Missing for 0.4.0 |
| --- | --- | --- | --- |
| New Tab's Personalize, feedback check-in and release postcard | `C/ntp/Personalize.tsx` (64) retains only open state, theme/profile/layout feeds and existing store actions. The RN panel, swatches, rings, layout miniatures and Radio helpers are deleted. | `UI/NewTab/PersonalizeView` and `Settings/NewTab/HostedPersonalize` host the button/panel and reuse `UI/Onboarding/OnboardingPersonalize` pickers. | Targeted New Tab drawing ports wired. JS actions and feeds remain for 0.4.2/0.4.6. |
| Same New Tab row: feedback | `C/ntp/CheckInBanner.tsx` feeds due-trial, profile, theme and icon state and dispatches the existing feedback/dismiss actions. | `UI/NewTab/CheckInBannerView`, `CheckInControl`, `CheckInMotion` and `Settings/NewTab/HostedCheckInBanner` draw the banner and its controls/motion. | Native drawing wired; stale presentation/profile actions are fenced and unmount cancels motion. JS due-trial policy remains. |
| Same New Tab row: release notes, conditional content | `C/ntp/Postcard.tsx` feeds notes, theme, profile and presentation receipts to native hosts. The catalog still has only `1.0`, so a clean 0.3.4 launch does not queue a postcard. The fixture explicitly queues matching content; the native host hides below 560×420 points while its intro continues, as RN did. | `UI/NewTab/PostcardView`, `PostcardInput` and `Settings/NewTab/HostedPostcard` draw the postcard/page, tooltip, artwork, stamp, scrolling and close controls. Artwork uses the existing native backdrop shader. | Native drawing wired; delayed dismiss/close and old page cleanup reject replaced presentations. JS notes/progress/actions remain. |
| Native site controls and prompts | `C/site/SelectionPopover.tsx` (57): delay, selection geometry and search actions feed native views; RN `Bar`/`SearchButton` drawing is removed. | `UI/PaneOverlays/SelectionBarView`; `Settings/PaneOverlays/HostedSelectionBar` for Little Solara, no-shell and Peek; existing browser pane host retained. | Targeted selection port wired. JS behavior and feeds remain for 0.4.2/0.4.6. |
| Native extensions toolbar, overlays and side panel | No proven RN pixels with normal native capabilities. Popup frames, install/permission/pin sheets and side-panel containers are now native-only. `ExtensionOverlays` returns null; side-panel host returns null, with a transparent spacer. | `Settings/Toolbar/NativeExtensionActionPopup`, `UI/Panels/ExtensionDialogViews`, `UI/SidePanel/ExtensionSidePanelView`, `Settings/SidePanel/NativeExtensionSidePanel`, native toolbar buttons. | Extension-button/badge RN drawing is deleted. Existing NSMenu renders context/overflow menus, with keyboard/AX actions on native extension buttons. Little Solara uses the same native popup frame through its existing root slot. JS toolbar models/menu actions/install/lifecycle remain 0.4.4/0.4.5 work. |
| Native media: sidebar/hover player, cast/share pickers, tab badges | No proven RN media-body pixels on the normal path. `TabBadges`, `PipBadge`, `CaptureBadge` are used only by the React strip fallback. Share-bar animation wrappers are transparent. | `UI/Media/{SidebarPlayerView,HoverPlayerCardView,ShareBarView,SharePickerView,CastPickerView,CliControlPillView}`; `UI/Primitives/{TabBadgesView,UnreadBadgeView,TabNumberHintView}`; `Settings/Media/NativeMedia`. | Retire/account for badge fallback consumers. Playback/share/cast decisions and replicas remain, but are not missing native pixel bodies. |
| Native peek, Little Solara, calendar and meeting cards | `C/LegacyContentCard.tsx` selects `SmallWindowPageHost` behind `littleSolaraShellActive`: Swift owns fill, rounded clipping and content sizing; RN supplies transparent placement and page state/actions. The legacy lane retains its RN clip. Calendar and countdown pixels were already native; the meeting fallback now also uses the native frame and motion. `C/layout/PaneOverlays.tsx` hosts native recovery UI. | `UI/LittleSolara/{LittleSolaraShellView,SmallBarView}`; `UI/Primitives/SmallWindowCardView`; `Settings/Media/SmallWindowPageHost`; `UI/Pages/{LiveCardsView,MeetingAlertFrameView}`; `UI/Sidebar/SidebarHoverSurface`; native SadTab host. | 0.4.2 native drawing/hosting source prepared. Existing engine page identity and session ownership are retained. Swift layout/state tests and driver expectations updated; VM compilation, drivers and matched light/dark/VoiceOver checks remain pending. |
| Native top strip, split chrome, swipe overlay and other layout | `C/layout/SwipeOverlay.tsx` (197) retains gesture/history actions and sends native commands. RN tint/rim, destination rows and their favicon drawing are removed. | `UI/PaneOverlays/SwipeCapsuleView`; `Settings/PaneOverlays/HostedSwipeCapsule` for Little Solara, no-shell and Peek; browser pane host retained. | Targeted swipe port wired. Layout ownership remains in its separate port. |
| Same layout row: frozen shared pages | `C/layout/frozenPage.tsx` (53) feeds snapshot/wash state and guards activation/painted receipts; no RN `Image`, wash or `Pressable` drawing remains. | Existing `UI/WindowShell/FrozenPageView` is mounted by `Settings/PaneOverlays/HostedFrozenPage`, with no window-layout changes. | Targeted frozen-page port wired on every existing consumer, including native-default pooled windows. JS handoff decisions remain. |
| Layout recovery (applies across roadmap rows) | `C/AreaBoundary.tsx` retains the two retry delays, quiet-pane behavior and Reload remount action; `AreaErrorRow` and `PlainFallback` only adapt state/events to a native host. | `UI/Primitives/AreaRecoveryView` and `Settings/Hosted/HostedAreaRecovery` draw the generic recovery row, with Debug-only error detail. `UI/Settings/StoreUnavailableView` remains the separate store-open failure case. | Targeted recovery port wired; keyboard and VoiceOver Reload use the same remount action. |
| Sidebar on the right | No additional RN pixel body to port for this feature. Current native geometry/dock assumes the left edge. | `UI/WindowShell/{ShellGeometry,SidebarDock}`, native sidebar/hover/drop hosts. | Native position setting/menus and mirrored layout, resize, hover, peek and drops. Native counterparts do not mean right-side support is implemented. |
| Only build visible sidebar rows | Default sidebar rows are already native. | `UI/Sidebar/SidebarView` creates/reuses by item key while iterating all layout items; scrolling does not materialize only a visible range. | Native viewport virtualization and row reuse; this remains performance work, not another RN pixel port. |
| Smarter launch ordering | No additional RN drawing component identified for this row. RN startup and native service startup still interleave. | Native startup policy, Settings prewarm, native history hints, tab-sleep runner and profile warmup. | Chrome-first/idle/priority scheduling and measurement. `main.tsx` still starts services at module load; `afterFirstWindow` uses a zero-delay task, not an idle scheduler. |

Evidence for the non-obvious gaps: `C/ContentCard.tsx` mounts headless `FrozenPage`; `C/LegacyContentCard.tsx` uses `!pooled` for legacy content;
`lib/pagesPool.ts` requires browser `windowShellActive`, pane roots and the pool. `Settings/WindowShell/NativeWindowShell`
admits browser windows only; `Settings/LittleSolara/NativeLittleSolara` instead mounts backdrop/bar/react slots.
Little Solara remains unpooled; `SadTab`, `SelectionPopover` and `SwipeOverlay` now mount existing native bodies inline.
During main-root/pane-root handoff the older `PageOverlays` wrapper can also run, but its component-level gates still
choose native prompt bodies/frames and native browser overlays; the wrapper alone is not proof of RN prompt pixels.

### Shared layout controls cutover

`C/layout/controls.tsx` now contains only geometry, modifier conversion, motion values and presence state.
The native input controls retain keyboard traversal, Return/Space and VoiceOver actions. First-click acceptance
stays opt-in under `51c0215b`; this cutover adds no first-click opt-in to sensitive actions.

| Former shared control | Original consumers and resolution |
| --- | --- |
| `ToolbarButton` | Toolbar, sidebar AddressBar, developer/translate/zoom indicators now use NativeToolbar / SidebarAddressBarView. Unconsumed RN indicator bodies are deleted; action/menu helpers remain. |
| `PanelHeader`, `PopoverValue`, `Toggle` | SiteControls and translation rows use SitePanelView. SiteControlsParts retains geometry only. |
| `PromptButton`, `PanelCloseButton` | Permission, password, autofill, external-app, blocked-popup and engine-offer prompts use PromptBodyView; chooser uses DeviceChooserView; zoom reset uses ZoomPanelView. Existing guards, choices and action IDs remain. |
| `Popover`, `PopoverRow` | PromptPopover supplies native placement; blocked popup rows use PromptBodyView; site/history/zoom use their existing native panel hosts. |
| `PopoverSeparator` | Download/history/site/prompt and group separators belong to their native bodies. |
| `PopoverSurface`, `popoverRowFill` | The no-shell GroupPanel now hosts SidebarGroupCardView; its private RN surface and row fill are deleted. |

The original shared-control cleanup retained the Downloads skin/button, ToolbarBackdrop and no-shell GroupPanel.
The follow-up below ports them. The small-window card now feeds a native fill; the legacy page composition retains only placement constants from controls.
The refused-session recovery lane also keeps native controls: JS supplies site context only when the native store is absent, settings/mute callbacks reject a stale tab URL, and the sidebar callback bridge connects independently of the Settings model. Native API 49 rejects older Debug hosts missing this recovery input and the merged New Tab/layout APIs.
The cutover passes unit tests, typecheck and a Debug build. Hidden drivers cover prompts, pages, zoom/history/downloads, both toolbar locations and hidden panes; a refused-session instance verifies the native site body and sidebar callback. AppKit input tests cover keyboard/AX guards and inactive first clicks. Twenty matched captures have 0 pt host-frame differences and pixel-identical control interiors; native-shell images are pixel-exact. Inline translucent edges differ with the page-compositor underlay. Real VoiceOver speech and light/dark hover/press feel remain owner checks.

### Downloads, backdrop and group cutover

Native API 51 supplies the three hosts. Downloads.tsx keeps formatting, menus, actions and placement policy;
DownloadsPanelView owns the bubble and fade/scale, and DownloadButtonView owns the former RN button.
Toolbar.tsx projects state into passive ToolbarBackdropView; Swift draws its band, developer stripes and divider.
GroupPanel.tsx projects rows and guarded actions into SidebarGroupCardView without the native shell too.
The shared group card preserves field selection across search, row-key traversal and detach, releases its hold after
focus leaves, and rejects restoration when another control owns focus. Inspection is Debug-only. New action controls
reject activation clicks; the existing outside-dismiss opt-in remains. Window-layout code is unchanged.

The targeted cutover passes 24 native control tests, typecheck, pnpm tests and the Debug build. Hidden checks pass
Downloads 14/14, magnet 1/1, window-toolbar 47/47, Developer Mode toolbar, four backdrop states and group 6/6 across
both shell modes. Matched Downloads/group outer frames differ by 0 pt; shell-on Downloads and the tinted toolbar
crops are pixel-exact. Developer stripe edges differ by at most 2/255 per channel. The reused group card has a
0.5 pt inner inset and a 1 pt narrower selected row; its empty-label cell adds 2 pt horizontal padding. In-process
text-opacity differences, composited material, physical motion and VoiceOver speech remain owner checks.

### Native-shadowed drawing retained as fallback

These files stay in the source totals. A native counterpart and a default-on flag do not make a fallback dead.

| Roadmap row / surface | Retained RN drawing | Default native coverage and gate |
| --- | --- | --- |
| Site controls and prompts | `DeveloperStripes` in retained AutoHideToolbar/TopTabStrip fallbacks; unused `NetworkBadge` inside otherwise-live `Autofill.tsx` | Site, prompt, chooser, engine-offer, history and zoom bodies now always use existing native hosts, including inline consumers; former capability-selected RN bodies are deleted. `NetworkBadge` can be deleted independently of live `requestAutofill`. |
| Extensions | None; transparent popup anchor adapter remains | RN extension-button/badge drawing is deleted. Native toolbar JSON model/buttons and NSMenu draw the menus. The transparent popup anchor adapter remains; native popup/frame/sheets/side-panel RN bodies are removed. |
| Media | `TabBadges` / `PipBadge` / `CaptureBadge` | Native sidebar/strip badges. RN imports lead only to retained React top-strip rows. |
| Peek / Little Solara / live cards | `PeekOverlay`/card/bar; `SmallChrome`'s `SmallBar`, `PageLabel`, `Progress`; `LiveItemCard` and PR/document helpers; RN hover frame around native `CalendarPreview` | Native pooled Peek; native small bar; native hover kinds/live cards. `SmallChrome` is consumed by old Peek, not the native small bar. Calendar/meeting card bodies and fallback alert motion are native; the RN alert wrapper only positions the native frame. |
| Strip / sidebar / profiles | `TopTabStrip` React rows/groups; `Sidebar` header/footer/update/glow; `ProfileIndicator`, `ProfileDots`, `TooltipAbove`, hover cards, `TabIcon`, `FolderMosaic` | Hosted strip/controls/peek and full native sidebar/pager/hover kinds. `ProfileNameMeasure`'s zero-height, zero-opacity text measures native-strip layout; it has no visible pixels. |
| Layout / toolbar / downloads | RN dock/tint/split dividers/drop/empty/toast, `AutoHideToolbar` | Native shell/dock, split chrome, toolbar/find/history and downloads. Find, history, downloads skin/button/motion and toolbar backdrop are native-only, including no-shell hosts. |
| Shared primitives and bootstrap | `Favicon`, `FaviconFallback` and `NewTabIcon` host the sidebar favicon renderer through `Settings/Primitives/HostedFavicon`; their image/initial drawing is removed. `Switch`, unconsumed settings-widget exports including `Checkbox`, `IconButton`, other RN primitives; `nativeApi.tsx` skew View/Text | The settings-widget exports are now unconsumed after prompt fallback removal; the containing module remains live through `useFormColors`. NTP does not use these settings widgets. Native `Symbol`, `Surface`, `VisualEffect`, shader/Metal views and hosted views are native drawing. API skew is an alternate startup, outside the normal matching-version lane; its requested settings auxiliary may be intercepted natively. |

`CommandPanel`/`CentredBar`/`Grow`, NTP outer layout, share-bar wrappers, native prompt wrappers, native player wrappers
and ordinary main/pane roots still mount React-managed views. Their transparent layout/measurement/animation around
native bodies is glue under this inventory's method. In particular `Grow`'s frame is native `Surface`, and its omnibox
rows/chips/buttons are native; the old “RN command-panel frame” description was incorrect.

`SOLARA_NATIVE_SHELL=0`, pane/pool/top-strip UI overrides remain real development paths; distribution ignores those
shipped UI overrides. `SOLARA_TAB_POOL=0` is a separate live pool escape hatch, including distribution, and can activate
legacy Peek and its explicitly nonnative overlays. Partial native scope and failed/unavailable capabilities are also
separate from normal native-default launch. Cached asynchronous hosted-kind registration (notably the strip) needs
runtime validation before declaring any early fallback unreachable. No fallback is marked dead merely from its default.

## Native coverage and remaining dependencies

Path keys: `UI/` = `native/SolaraKit/Sources/SolaraUI/`; `Store/` = sibling `SolaraStore/`; `Sync/` = sibling `SolaraSync/`.
`Live/` and `Persistence/` are sibling `SolaraLive/` and `SolaraPersistence/`.
`Settings/` = `packages/settings/ios/`; `Shell/` = `packages/shell/ios/`.
Brace lists name separate files. All listed native filenames end in `.swift` unless stated.
“Default” means the source-selected normal distribution lane with full store ownership and available capabilities.

| Group | Native code already present | RN lane and work that blocks removal |
| --- | --- | --- |
| Bootstrap | `apps/browser/macos/Solara-macOS/AppDelegate.swift`; `Shell/{Windows,AppModule}`; `Settings/Services/NativeAppStartup` | Always boots JS on the normal entry. Move service startup, first-window ordering, skew/error presentation, and root creation. The native shell still retains the main RN root. |
| Shared UI | `UI/Primitives/{PopoverView,PopoverBubbleView,IconRing,CornerBadge,TabBadgesView,UnreadBadgeView,TabNumberHintView}`; `UI/Settings/SettingsControls`; native primitives exposed through shell | RN buttons, switches, tooltips, icons, and error UI survive through callers. Replace live consumers, then remove retained fallback widgets. Native store-unavailable UI does not replace every `AreaBoundary` error path. |
| Window layout | `UI/WindowShell/{WindowShellView,SidebarDock,DockAnimator,DockMotion,ShellGeometry,FrozenPageView}`; `Settings/WindowShell/NativeWindowShell`; `Shell/ChromeWindows` | Native shell/dock default. RN still composes the window and feeds geometry, backdrop, modal state, profile paging, and drag targets. RN dock/tint branches remain fallback. |
| Page hosting | `UI/TabPool/{TabViewPool,PageIssuer,PageRegistry,RNPageCallPolicy}`; `UI/PaneOverlays/{PaneRoots,PaneOverlays,SadTabView,SwipeCapsuleView}`; `Settings/{TabPool/TabPoolHost,PaneOverlays/NativePaneRoots,PaneOverlays/PanePrompts}` | Native engine-page pool default when available. RN `ContentCard`, page events, planning/props, overlay hints, and root handoff remain live. Move that orchestration and native fallback/error coverage before removing roots. `FrozenPage` now mounts native snapshot/wash hosting even with the pool; Little Solara remains unpooled. |
| Split panes | `UI/Split/{SplitChromeView,SplitPanesView,SplitSlots,SplitDividerView,SplitDropZonesView,SplitEmptyStateView}`; `Settings/Split/NativeSplitChrome`; `Store/Splits` | Native pooled chrome default. JS still chooses pane actions, feeds toolbars/toasts, and retains sizing/drop/empty-state fallbacks. Native chrome alone does not remove JS commands. |
| Sidebar | `UI/Sidebar/{SidebarView,SidebarChrome,SidebarFolderPanel,SidebarGroupCard,SidebarIconPicker,SidebarHoverSurface,TabSearchPanel,TabSwitcherPanel}`; `Settings/Sidebar/{NativeSidebar,NativeSidebarShell,NativeSidebarDock,NativeSidebarHoverCard,NativeTabPickers}` | Rows and full column are native by default gates. JS still feeds theme/media/live/selection and handles menus, rename, close, search and hover. With the native store, group buttons and the group menu, tile folders and file/link drops are decided in Swift; the JS handlers are their fallback. Header/footer/hover pixels remain fallback; GroupPanel now hosts the same native group card without the shell. |
| Top strip | `UI/TopStrip/{TopStripView,StripPageView,StripControls,StripPeekView,StripDrag,StripContext,StripLayout}`; `Settings/TopStrip/{NativeTopStrip,NativeTopStripPeek}`; `Store/StripQuery` | Native default; 1,754-line RN strip remains behind capability checks. Move JS callbacks, entry policy, and reorder policy. Group and folder menus, group buttons and tuck are decided in Swift with the native store; JS keeps the fallback. Verify cached registration timing before calling the fallback dead. |
| Toolbar | `UI/Toolbar/{ToolbarView,ToolbarState,ToolbarUrlFieldView,SidebarAddressBarView}`; `UI/Find/FindBarView`; `UI/AutoHide/ToolbarAutoHide`; `UI/Panels/HistoryPanelView`; `Settings/{Toolbar/ToolbarModule,Find/FindBarModule,AutoHide/AutoHideModule}` | Native toolbar/find default. JS still builds button/state JSON, handles clicks, history, URL edits, translation, focus, replace, and visibility. RN main/sidebar toolbar, backdrop and history bodies are removed; Find controls and their surface draw only in Swift on every existing find mount, including Little Solara and legacy Peek; the find adapter retains state/actions and transparent layout/motion. |
| Omnibox | `UI/Omnibox/{OmniboxBarView,OmniboxPanelHostView}`; `UI/NewTab/{HeroBarModel,OmniboxCommandSources,OmniboxWorkspaceSources,OmniboxCommandCatalog}`; `Settings/Omnibox/{NativeOmniboxView,NativeOmniboxSources}` | Native fields/suggestions; JS still owns open/switch dispositions, action dispatch, clipboard menus, file chips, focus, and extension/action feeds. Workspace-tab feed is suppressed under native-source mode. |
| New Tab | `UI/NewTab/{NewTabHeroView,HeroBarContent,HeroField,BarSurfaceView,NewTabLayout}`; `Settings/NewTab/{NativeNewTabView,NewTabModule}` | Hero and Personalize are native-only. `Settings/NewTab/HostedPersonalize` hosts the native button/panel and existing Swift onboarding theme/layout pickers. Feedback check-in and release postcard/page now use Swift hosts too; their adapters retain state, actions and feeds. |
| Bookmarks | `UI/Pages/{BookmarkFormView,BookmarksPageView}`; `Settings/Pages/PagesModule`; `Settings/NativeHistoryCatalog` | Dialogs are native. The bookmarks bar is native (`SolaraUI/BookmarksBar`, `Settings/BookmarksBar`); `NativeBookmarksBar.tsx` only feeds it state and runs its actions. JS retains edit/menu/undo routing and the display projection. NativeBookmarkCoordinator/BookmarkPump own durable edits, Chrome reconciliation and migration; `lib/bookmarks.ts` is now a subscription/reload bridge. |
| Profiles | `UI/Pages/CreateProfileFormView`; `UI/Settings/Panes/{ProfilesPane,ProfileDetailsPane,ProfileSheets}`; `UI/Sidebar/SidebarChrome`; `Store/ProfileActions` | Create form is native. Indicator/dots are RN fallback when the full native column is unavailable. JS still selects profile defaults, dispatches creation, and supplies form data. |
| Settings | `UI/Settings/{SettingsWindowView,SettingsNavigation,SettingsSearch,SettingsIndex}`; `UI/Settings/Panes/{GeneralPane,SyncPane,PrivacyPane,PasswordsPane,AutofillPane,ExtensionsPane,ThemeEditor}`; `Settings/{NativeSettingsWindow,SettingsJS,Adapters/SettingsAdapters}` | Native auxiliary window by default. JS topic/RPC server still services profiles, sync, import, privacy integration, password CSV, and resource caches. Extension/password/autofill CRUD already have direct native adapters. Only the nonvisual `useFormColors` hook serves normal native consumers; the RN settings-widget exports, including `Checkbox`, are unconsumed. NTP uses onboarding pickers instead. |
| Onboarding | `UI/Onboarding/{OnboardingOverlayView,OnboardingSteps,OnboardingPersonalize,OnboardingPairing,OnboardingSyncView}`; `UI/Tour/{ToolTourView,ToolTourModel}`; `Settings/Onboarding/{NativeOnboarding,OnboardingAdapter}`; `Settings/Tour/NativeToolTour` | Overlay and tour are native-only. Release enables first launch; Debug requires its onboarding flag (`OnboardingAdapter.swift:166`). JS still tracks sessions/tour, opens import, pins sites, and publishes context. The NTP reuses Swift personalization pickers; its RN personalization helpers are deleted. |
| Import | `UI/Import/{ImportWindowView,ImportModel,ImportComponents,ImportData}`; `Settings/{NativeImportWindow,Adapters/ImportAdapter}`; `Store/Import` | Window pixels native. Adapter invokes JS discovery/unlock/run/cancel/Safari/HTML/Dia flows. Move application of imported workspace data, progress/error state, and coordination with import/engine services. |
| Internal pages | `UI/Pages/{HistoryPageView,BookmarksPageView,DownloadsPageView,ClearDataDialogView}`; `Settings/{Pages/PagesModule,NativeHistoryCatalog}` | Native-only page wrappers. JS still handles navigation, deletion, confirmation, bookmark groups/import/Arc restore/undo, downloads commands, themes, and URL classification. |
| Downloads | `UI/Downloads/{DownloadsListView,DownloadsPanelView,DownloadMagnetView}`; `Settings/Downloads/{DownloadsModule,NativeDownloadsPanel,NativeDownloadMagnet}` | Panel, list and button draw natively in shell, no-shell and Little Solara lanes. Swift owns panel fade/scale; RN drawing is removed. JS still formats/feeds rows, routes menus/actions/open-when-done, measures placement, and triggers magnet state. |
| Extensions | `UI/SidePanel/ExtensionSidePanelView`; `UI/Panels/ExtensionDialogViews`; `Settings/{SidePanel/NativeExtensionSidePanel,Toolbar/NativeExtensionActionPopup,Adapters/ExtensionsAdapter}`; `packages/solaracore/ios/ExtensionsModule.swift` | Popup frame, install/pin sheets and the complete side panel are native-only, including header, resize edge, white empty/loading fill and directly owned standalone engine page. `ExtensionOverlays` and the panel state host return null; `SidePanelSpacer` is transparent layout. RN extension-button/badge exports are deleted from the retained toolbar-model module. Existing NSMenu draws context/overflow menus; native buttons expose keyboard and AX actions. Little Solara hosts the same popup in its existing root slot. JS still owns models, menu actions, installation and popup/panel lifecycle. Native empty-page transitions retain the current action identity and conditional focus recovery; view and host layout/lifetime tests cover the existing owner. |
| Site and prompts | `UI/SitePanel/SitePanelView`; `UI/Prompts/{PromptBodyView,DeviceChooserView}`; `UI/PaneOverlays/{PanePromptPage,PanePromptSpecs,PanePermissions,SelectionBarView}`; `Settings/{Services/NativeSiteControls,PaneOverlays/PanePrompts,SitePanel/SitePanelModule}` | Pooled prompts/site panels are native. Pooled site page commands use native `PageIssuer`; other bindings and `site.action` still bridge JS. Move JS engine offers, translation, selection search/copy, and compatibility policy. RN prompt/device/site/zoom bodies are removed; their native hosts still receive JS state and actions. |
| Media | `UI/Media/{SidebarPlayerView,HoverPlayerCardView,ShareBarView,SharePickerView,CastPickerView,CliControlPillView}`; `Settings/Media/{NativeMedia,MediaModule}` | Players/pickers/control bodies native. JS still owns session/artwork replicas, source filtering/thumbnails, share/cast selection, playback/mute/PiP/dismiss actions, and share-bar layout animation. RN badge fills remain only in the retained React top-strip branch; unread and number badges have native views. The RN share-bar wrapper only animates/clips native content. |
| Peek | `UI/Peek/{PeekOverlayView,PeekMotion}`; `Settings/WindowShell/NativePeek`; `Store/Peek` | Native peek when pooled; RN overlay otherwise (`LegacyContentCard.tsx`). JS still publishes state and routes close/expand/hold/pinch. Move supported fallback pixels and remaining lifecycle policy. |
| Little Solara | `UI/LittleSolara/{LittleSolaraShellView,SmallBarView}`; `Settings/LittleSolara/NativeLittleSolara`; `Shell/Windows` | Native shell/bar wraps the main root. JS still composes content and command/download/extension overlays and handles open/expand/window targeting. This host does not start browser pane roots: the active native shell uses `SmallWindowPageHost` for fill, rounded clipping and content sizing around the same engine page subtree. The legacy lane retains RN clipping; transparent RN placement and page state/events remain; swipe destinations, selection-search and crash/unresponsive UI now host Swift views. Shared favicon adapters also host native sidebar icons. `SmallChrome` pixel helpers actually serve legacy Peek, not the native small bar. |
| Live cards | `UI/Pages/{LiveCardsView,MeetingAlertFrameView}`; `UI/Sidebar/{SidebarLiveCard,SidebarMeetingCountdown}`; `Settings/Pages/MeetingAlertHost` | Calendar/alert card bodies and sidebar meeting countdown are native. `NativePageView` also uses `MeetingAlertFrameView` on the fallback lane; its RN wrapper only positions the card, with no RN opacity/scale/translation. The calendar fallback frame is the native `Surface`. Other RN live hover cards remain fallback when their native kind is unavailable. JS still computes labels, join/related links, alerts, and placement. Standalone `MeetingCountdown` and `NextMeetingBadge` were deleted on 2026-11-14 after a repository-wide consumer check. |
| Live services | `Live/{Engine,Commands,Documents,Accounts,CalendarEngine,MeetingGroups,Meetings,GitHub,Rows}`; `Settings/Live/{NativeLiveEngine,NativeLiveEffects}` | Fetch jobs, secrets/calendar and live persistence are native. JS replicas remain; auth tabs, item-to-tab reuse, group/autogroup, cleanup, and join/open routing still run. Do not describe the live JSON replica as a second durable writer. |
| Store | `Store/{Store,Command,ChangeSet,StateJSON,Hydrate,SessionLoader,Tabs,Windows,Groups,Organize,Splits,PinMirror,PinShare,TabShare,TidyPins,TileFolders,PageReports}`; `packages/store/ios/{NativeStore,StoreModule,RNPageReports}.swift`; `Persistence/{Writer,SolaraDatabase,Importer}` | Native full ownership default. JS Zustand replica and revision guards remain. Wrapped workspace actions use native reducers; retained TS reducer bodies are largely fallback, while exported helpers can remain live. Remove unwrapped library/UI stores, replica consumers, and legacy migrations before deleting TS store code. |
| Sync | `Sync/{Scope,Files,HLC,Order,Canon,StateDecode,EditJournal,StoreAdapters,HostedAdapters,PinnedAdapters,Extensions,LedgerPasswords,PasswordLedger}`; `Store/{SyncPinsCommand,SyncPinned,SyncPinnedApply}`; `packages/sync/ios/SyncModule.swift` | JS sync orchestrator remains live when sync is enabled. Native transport/crypto/pairing and native pin apply do not replace JS adapter selection, cycles, sync.json, metadata, recovery, or merging. Native `syncScope` exists in CLI use; app ownership is **unverified** because inspected app adapters import SolaraSyncAdapter, not the SolaraSync library. |
| Lib | `UI/Services/{AppStartupPolicy,AppIntegrationPolicy,ScriptCommands,CliControlSync,MemoryTrimSchedule,SiteControlsLogic}`; `Settings/Services/{NativeAppStartup,NativeAppIntegration,NativeCliControl,NativeUserScripts,NativeMemoryTrim}`; `Shell/{Menus,Windows,Notifications,UserScripts}`; `Store/{ChromeTabs,NativeCaches,ProfileDataCleanup}` | JS window/menu/command/focus/engine/lifecycle integration remains live, including pinned-link disposition and lazy-profile admission. `Settings/Services/{NativeConfigNotifier,NativeHooks,NativeProfileWarmup}`, `packages/store/ios/{NativeConfigFiles,NativeTabSleep}.swift` and native config/hooks UI already exist; they introduce no new RN surfaces. Library sync/cache/migration services run even with native workspace. Native service files cover parts only; for example native memory trim still invokes JS compact. |

## Data ownership that still matters for 0.4.5

- `src/store/nativeStore.ts:253,288,400` forwards wrapped commands, applies revision commits, and guards writes to owned state. `store/browser.ts:204` disables several JS normalization/mirror observers under full ownership. This is real native ownership.
- `src/lib/persist.ts` starts bookmark/history/favicon services in the native branch too. `lib/bookmarks.ts` subscribes to native projection and requests catalog reloads; it owns no Chrome writes, cache saves or migration. NativeBookmarkOwner and BookmarkPump own those bookmark lifetimes. `lib/history.ts` retains legacy history redaction/migration and tombstone handling.
- `src/lib/favicons.ts` still owns a JS cache and extraction/lookup work. `lib/launchLook.ts:31` still writes `launch-look.json` during final flush. Native image storage or a native history catalog does not eliminate these JS copies.
- `src/sync/engine.ts:526,679,749,2133` retains durable sync metadata, adapter construction, cycles, and startup. `sync/pinned.ts:70` delegates native apply under workspace ownership. Other data flows remain JS-coordinated.
- `src/components/settings/native/resources.ts`, page state, media state/artwork, extension state, sidebar state, and other local caches also remain. “The data layer is native” needs native owners or deletion of these replicas, not only a native session writer.

## RN registrations and native roots

| Item | Count | Evidence and lifetime |
| --- | --- | --- |
| Registration call sites | 3 | `src/main.tsx:76` registers `main`; `src/PaneRoot.tsx:35` registers `pane`; `src/nativeApi.tsx:22` registers a skew-screen `main`. |
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

## Removed source and retained app-dead source

On 2026-11-14, the cleanup removed **4 unreferenced files / 172 lines** after checking repository-wide imports,
reexports, dynamic imports/requires, filename-based source loaders, tests, exported symbols and native registration.
Historical perf census/ratchet names are measurements, not executable consumers. The AppRegistry entries remain main
(normal/skew) and pane; Metro has no glob registration for these files.

| Deleted path under `apps/browser/src/` | Lines | Evidence |
| --- | ---: | --- |
| `components/live/NextMeetingBadge.tsx` | 64 | No consumer for `NextMeetingBadge`; old perf census names are not executable consumers. |
| `components/glass.tsx` | 60 | No consumer for `GlassFill`, JS `liquidGlass` or its exported constants. |
| `components/live/MeetingCountdown.tsx` | 42 | No consumer for `useMeetingCountdown` / `MeetingTimeLabel`; native sidebar countdown is separate. |
| `components/settings/sheet.ts` | 6 | No consumer for `useSettingsSheet`, `showSettingsSheet`, `closeSettingsSheet`. |
| `live/rows.ts` | 51 | Only consumer was `live/folderOptions.test.mjs`; its two cases tested only this dead helper. Deleted the 16-line test too; independent Swift folder-options coverage remains. |
| `components/site/DeveloperUrlInput.tsx` | 50 | Its React toolbar consumer was removed by the layout-controls cutover; the native toolbar owns the developer URL field. |

The fifth source deletion brings the total to **5 files / 223 lines**, plus **1 test / 16 lines** excluded from source
budgets. The later layout-controls deletion adds **1 file / 50 lines**. The other **3 app-dead files / 118 lines** remain because deleting their consumers would remove active coverage:

| Retained path under `apps/browser/src/` | Lines | Reason |
| --- | ---: | --- |
| `sync/commandJournal.ts` | 58 | Five step5 test files use this oracle alongside live native-store/sync-origin behavior. `step5-fallback` checks the fallback protocol; `step5-followups` checks sync tokens, transaction busy/retry, switch ordering and deferred effects. Preserve these tests until the oracle is migrated. |
| `components/omnibox/dropdownStart.ts` | 47 | Its unit test reads/transpiles the source. `native/SolaraKit/Scripts/omnibox-idle-fixtures.mts:55` also hashes it for the native `idle-tabs.json` fixture; deleting it breaks fixture verification. |
| `lib/profileThemeActions.ts` | 13 | The preset case in `sync/themePairing.test.mjs` tests late theme download/adoption and propagation to another Mac. The suite also covers live sync pairing, persistence and refused admission; it is not an obsolete helper-only test. |

The unconsumed `NetworkBadge` export in `components/site/Autofill.tsx` is removable, but the file's `requestAutofill`
function is live; do not delete the whole file.

Do not infer deadness from an app-only import graph: `components/omnibox/knownHosts.ts` (30) is used by
`scripts/perf/{micro-bench,suggest-hermes}.mjs` and tests; both pinned sync fixtures (691 lines) are test inputs and
pinned by native `sources.json`; `react-native-macos.d.ts` (10) is an ambient declaration included by tsconfig.
Together with the three retained files above, these account for seven app-graph orphans (849 lines total), not additional safe deletions.
The scan followed literal imports/reexports/require/dynamic import repository-wide, checked filename-based source
loaders and exported-symbol references, and retained `index.js` / AppRegistry/native main/pane bootstrap entries.

Before the layout-controls cutover, no whole-file subgraph was proven reachable only behind a retired flag. `killSwitches.ts`'s `live: false` is metadata:
`switchOn()` still returns an override, cached value or true without consulting `live`. Native-default capability
fallbacks, old store reducer branches with live exported helpers, and JS tab sleep's fallback/manual paths are not
whole-file deletion candidates just because native implementations exist.

## Columns by roadmap version

The milestones follow docs/roadmap.md. Each primary responsibility has one exit milestone.
These totals include dead modules and retained fallbacks; they are source budgets, not remaining live pixel counts.
A file can be deleted earlier when unused; retained compatibility code must be deleted by 1.0.0.
Secondary work in a file moves with its own column: drawing inside a b or d file still has to go by 0.4.0.

| Version | Leaves | Files | Lines | Largest path groups (lines in that column) |
| --- | --- | ---: | ---: | --- |
| 0.4.0: React Native draws nothing | a, drawing | 21 | 4,778 | Top strip 1,755; Sidebar 675; Toolbar 500; Split panes 461; Settings 311 |
| 0.4.2: commands and orchestration | b, commands and orchestration | 135 | 14,487 | Lib 6,178; Window layout 1,725; Page hosting 1,679; Settings 1,043; Omnibox 988 |
| 0.4.4: remaining interaction behavior | b, interaction behavior | 100 | 14,274 | Store 5,579; Sidebar 2,459; Site and prompts 2,005; Extensions 1,459; Window layout 1,411 |
| 0.4.5: the data layer is native | c, data | 75 | 13,406 | Sync 6,050; Store 2,920; Lib 2,060; Settings 693; Shared UI 501 |
| 0.4.6: React Native off by default | d, glue, once nothing needs a root | 70 | 4,821 | Sidebar 1,147; Window layout 1,107; Shared UI 741; Lib 323; Live services 239 |
| 1.0.0: React Native deleted | everything retained, plus the RN host, Expo modules, Metro, pods and patches outside apps/browser/src | 401 | 51,766 | see the 1.0.0 row below |

React Native roots left today: 3 AppRegistry registrations (`main`, `pane`, and the API-skew screen, which reuses `main`),
so 2 module names; one `main` root per browser or Little Solara window, plus a `pane` root for each pane whose overlay
is shown (hidden ones retire after 1 s). Settings and Import windows normally have none.

## Milestone removal order

Each cell lists the largest dependencies first. These are proposed work boundaries inferred from the inspected call paths.

| Milestone | Required moves | Exit evidence to collect later |
| --- | --- | --- |
| 0.4.0: draws nothing in RN | NTP extras and their onboarding pickers now draw natively; Little Solara fill, clipping and content sizing are native on its active shell, retaining the same engine page; calendar/countdown/side-panel pixels were already native and fallback meeting motion is now native (VM verification pending); frozen handoff, swipe, selection and SadTab bodies are now native; generic render recovery and shared favicon drawing are now native. Bookmarks bar and extension popup/frame/sheets/panel pixels are already native. Main/sidebar toolbar controls and prompt/site/chooser/history/zoom/download-list bodies now use native hosts only. Downloads skin/button/motion, toolbar backdrop and no-shell group card now host Swift views. Finish retained find, legacy Peek and API-skew pixels; verify recovery/capability lanes. Transfer RN-driven layout/animation where native content still depends on it. Secondary a work inside b/d files also counts. | Every supported release surface and recovery path draws native pixels. Exercise unavailable-capability and handoff paths. Retained development fallbacks must be outside the milestone's supported release lane. |
| 0.4.2: commands and orchestration | Move commands, menus, shortcuts, window/focus/navigation orchestration, omnibox actions, Settings and Import RPC actions, and find. | Native views and commands work with JS action/RPC handlers disabled. Native UI has no required JS decision round trip. |
| 0.4.4: remaining interaction behavior | Move sidebar/top-strip drag, selection, close, rename, pin and move; folders and groups; media, extension, prompt and translation lifecycles; live auth/meeting integration; TypeScript fallback reducers. | Native UI has no required JS decision round trip across retained interaction behavior. |
| 0.4.5: data layer is native | Move the JS sync coordinator/adapters/durable metadata and remaining history reconciliation/migrations first. Bookmark reconciliation, migration and caches moved in 0.3.0. Remove remaining JS history/favicon/launch caches and unwrapped Zustand stores. Replace or delete UI/page/media/extension replicas. Keep native writer/ownership safeguards during the transition. | Full persistence, restart, import, sync, privacy deletion, and recovery work without JS data services. Native SolaraSync must be wired into the app, not merely present in the library. |
| 0.4.6: RN off by default | Remove mandatory `AppDelegate` main/pane root creation and `main.tsx` startup dependency. Give native app startup, window/menu binding, settings services, page props, and root handoff independent lifetimes. Default to no RN host/bridge; any compatibility switch must explicitly opt in. | Signed distribution starts, opens windows/tabs/settings, syncs, quits, and restores with no RN runtime or roots. UI switches being on is insufficient evidence. |
| 1.0.0: RN deleted | Delete retained RN roots, JS UI/decision/data fallbacks, JSON/RPC topics, test doubles, and skew plumbing. Remove Expo/RN native bindings, package dependencies, Metro/bundle phases, Pod integration, RN patches, and tests/harnesses that require RN. Audit package TS wrappers beyond this appendix before deleting shared pure TS. | Dependency/source/build audit finds no RN/Expo host or required bundle. Native-only release and recovery acceptance pass. Preserve engine/native APIs still used by the app. |

The 401-file appendix is not the full deletion boundary.
Outside it are `apps/browser/index.js`, macOS AppDelegate/Podfile/Xcode configuration, `packages/{settings,shell,solaracore}/src` wrappers, Expo module adapters, dependency manifests/locks, RN dependency patches, and build/test tooling.
These need a separate dependency closure check before 1.0.0. No package deletion safety claim is made here.

## Appendix: full file inventory

Paths are repository-relative. a = RN pixels; b = behavior; c = data; d = glue.
Each path appears once. The milestone is the primary responsibility exit date (all retained fallback code is deleted by 1.0.0).
Notes name secondary work and immediate deletion candidates. Whole-file lines remain counted even when removable now.

| Path | Lines | Column | Milestone | Note |
| --- | ---: | :---: | :---: | --- |
| `apps/browser/src/App.tsx` | 91 | d | 0.4.6 | Native default feature-root composition; bounds come from native anchors |
| `apps/browser/src/PaneRoot.tsx` | 41 | d | 0.4.6 | Native-slot feature guest registration/context; no window layout ownership |
| `apps/browser/src/components/AreaBoundary.tsx` | 163 | b | 0.4.2 | Recovery retries/remount and native row state/events; Debug-only failure fixture |
| `apps/browser/src/components/AutoHideToolbar.tsx` | 275 | a | 0.4.0 | Fallback toolbar strip pixels; also b motion |
| `apps/browser/src/components/CliControlPill.tsx` | 61 | d | 0.4.6 | Native CLI-pill placement/feed |
| `apps/browser/src/components/CommandPanel.tsx` | 299 | b | 0.4.2 | Panel geometry/focus; transparent RN Grow around native Surface/bar, no RN frame fill |
| `apps/browser/src/components/ContentCard.tsx` | 84 | b | 0.4.2 | Native content/action feeds; lazy complete legacy card selector |
| `apps/browser/src/components/Downloads.tsx` | 361 | b | 0.4.2 | Download status/menu/actions and placement policy; native panel/button adapters draw nothing |
| `apps/browser/src/components/EmptyCard.tsx` | 7 | d | 0.4.6 | Empty-card native composition |
| `apps/browser/src/components/FindBar.tsx` | 110 | b | 0.4.4 | Native-only find controls and Surface; JS find/replace/focus state/actions and transparent layout/motion remain. Pooled native Peek has no find mount. |
| `apps/browser/src/components/HoverSlot.tsx` | 30 | d | 0.4.6 | Transparent layout slots |
| `apps/browser/src/components/NativeAutoHide.tsx` | 58 | b | 0.4.2 | Toolbar reveal policy; also d feed |
| `apps/browser/src/components/NativeToolbar.tsx` | 331 | d | 0.4.6 | Native toolbar JSON model; also b click/menu policy |
| `apps/browser/src/components/NewTabPage.tsx` | 102 | b | 0.4.2 | Hero geometry/intro policy; also a extras composition |
| `apps/browser/src/components/PooledPageProps.tsx` | 28 | d | 0.4.6 | Pooled-page prop feed |
| `apps/browser/src/components/ProfileIndicator.tsx` | 123 | a | 0.4.0 | Fallback profile label; also b menu |
| `apps/browser/src/components/Sidebar.tsx` | 158 | a | 0.4.0 | Fallback sidebar chrome; also b routing |
| `apps/browser/src/components/Switch.tsx` | 87 | a | 0.4.0 | RN switch track/thumb |
| `apps/browser/src/components/Toolbar.tsx` | 59 | d | 0.4.6 | Native toolbar/backdrop state and geometry adapter; no RN band, stripes or hairline |
| `apps/browser/src/components/TooltipAbove.tsx` | 66 | a | 0.4.0 | RN tooltip label/motion |
| `apps/browser/src/components/WindowToolbar.tsx` | 51 | b | 0.4.2 | Toolbar routing; also c chrome cache |
| `apps/browser/src/components/bookmarks/BookmarkDialog.tsx` | 58 | b | 0.4.2 | Bookmark defaults and close handling |
| `apps/browser/src/components/bookmarks/EditBookmarkDialog.tsx` | 36 | b | 0.4.2 | Bookmark editor state and callbacks |
| `apps/browser/src/components/bookmarks/NativeBookmarkForms.tsx` | 108 | b | 0.4.2 | Bookmark editing rules; also d host |
| `apps/browser/src/components/bookmarks/NativeBookmarksBar.tsx` | 84 | d | 0.4.6 | Native bookmarks bar placement/feed; also b actions |
| `apps/browser/src/components/bookmarks/actions.ts` | 119 | b | 0.4.2 | Bookmark menu/action routing |
| `apps/browser/src/components/bookmarks/bookmarksBarActions.ts` | 56 | b | 0.4.2 | Bookmarks bar menu/open/edit routing |
| `apps/browser/src/components/bookmarks/bookmarksBarDrop.ts` | 29 | b | 0.4.2 | Bookmark link-drop validation and mutations |
| `apps/browser/src/components/bookmarks/bookmarksBarPolicy.ts` | 21 | b | 0.4.2 | Bookmarks bar visibility/capability policy |
| `apps/browser/src/components/bookmarks/bookmarksBarSnapshot.ts` | 64 | d | 0.4.6 | Native bookmarks bar state/theme projection |
| `apps/browser/src/components/bookmarks/edit.ts` | 45 | b | 0.4.2 | Bookmark edit/undo decisions |
| `apps/browser/src/components/bookmarks/formGate.ts` | 13 | b | 0.4.2 | Bookmark form duplicate-submit guard |
| `apps/browser/src/components/downloadsPlacement.ts` | 43 | b | 0.4.2 | Download panel geometry rules |
| `apps/browser/src/components/extensions/ExtensionOverlays.tsx` | 128 | b | 0.4.4 | Native install/pin sheet lifecycle/actions; no RN popup/frame |
| `apps/browser/src/components/extensions/SidePanel.tsx` | 100 | b | 0.4.4 | Native side-panel lifecycle/width/actions; only transparent RN spacer |
| `apps/browser/src/components/extensions/ToolbarExtensions.tsx` | 210 | b | 0.4.4 | Native toolbar model/menu actions and transparent popup anchor; RN buttons/badge deleted |
| `apps/browser/src/components/extensions/actions.ts` | 50 | b | 0.4.4 | Extension menu/action routing |
| `apps/browser/src/components/extensions/bridge.ts` | 483 | b | 0.4.4 | Extension event/install/navigation policy |
| `apps/browser/src/components/extensions/searchEngines.ts` | 35 | b | 0.4.4 | Extension search-engine policy |
| `apps/browser/src/components/extensions/sidePanels.ts` | 67 | b | 0.4.4 | Side-panel eligibility/open/close/URL synchronization; also c request maps |
| `apps/browser/src/components/extensions/state.ts` | 361 | b | 0.4.4 | Extension install/configure/menu/popup lifecycle policy; also c replicas |
| `apps/browser/src/components/extensions/store.ts` | 108 | c | 0.4.5 | Extension runtime/UI store and schema; also b selectors |
| `apps/browser/src/components/extensions/webkitPill.ts` | 25 | b | 0.4.4 | Engine-specific extension button model/width policy |
| `apps/browser/src/components/import/apply.ts` | 351 | b | 0.4.2 | Import discovery/apply orchestration; also c |
| `apps/browser/src/components/import/arcTheme.ts` | 101 | c | 0.4.5 | Imported Arc theme conversion |
| `apps/browser/src/components/import/module.ts` | 14 | b | 0.4.2 | Import module capability gate |
| `apps/browser/src/components/layout/HistoryPopover.tsx` | 72 | b | 0.4.2 | History disposition/actions and native panel feed; RN rows removed |
| `apps/browser/src/components/layout/NativeSplitToolbars.tsx` | 15 | d | 0.4.6 | Toolbar JSON/callback relay |
| `apps/browser/src/components/layout/NativeStripControls.tsx` | 77 | d | 0.4.6 | Native controls/glow JSON feed |
| `apps/browser/src/components/layout/NativeTopStrip.tsx` | 369 | d | 0.4.6 | Strip JSON feed; also b actions, the fallback for group and folder actions Swift decides with the native store |
| `apps/browser/src/components/layout/PaneOverlays.tsx` | 29 | d | 0.4.6 | Native SadTabView hosting and browser overlay feed; no RN recovery pixels |
| `apps/browser/src/components/layout/sadTabState.ts` | 8 | d | 0.4.6 | Native SadTab state/theme projection |
| `apps/browser/src/components/layout/ProfileSwipe.tsx` | 113 | b | 0.4.2 | Profile swipe decisions; native tint placement |
| `apps/browser/src/components/layout/ShellBackdrop.tsx` | 42 | d | 0.4.6 | Native backdrop placement/feed |
| `apps/browser/src/components/layout/SidebarDock.tsx` | 489 | b | 0.4.4 | Dock/motion decisions; also a fallback surface |
| `apps/browser/src/components/layout/SplitChrome.tsx` | 344 | a | 0.4.0 | Fallback divider/drop/toast pixels; also b |
| `apps/browser/src/components/layout/SplitEmptyState.tsx` | 117 | a | 0.4.0 | Fallback pane search pixels; also b |
| `apps/browser/src/components/layout/SwipeOverlay.tsx` | 197 | b | 0.4.4 | Gesture/navigation policy and native SwipeCapsuleView messages; no RN capsule or list |
| `apps/browser/src/components/layout/TopTabStrip.tsx` | 1755 | a | 0.4.0 | Fallback tab-strip pixels; also b drag/menu |
| `apps/browser/src/components/layout/WindowProfile.tsx` | 26 | d | 0.4.6 | Native profile/neighbour mirror |
| `apps/browser/src/components/layout/controls.tsx` | 48 | b | 0.4.2 | Drawing-free geometry/modifier/motion/presence adapters; native consumers replace shared controls |
| `apps/browser/src/components/layout/devExpose.ts` | 13 | d | 0.4.6 | Development exposure facade |
| `apps/browser/src/components/layout/dockMotion.ts` | 79 | b | 0.4.2 | Dock motion/edge/hit rules; also c |
| `apps/browser/src/components/layout/fileDrop.tsx` | 132 | b | 0.4.2 | Drop validation and tab placement; native-store sidebar and native-layout strip drops open in Swift (DroppedTabs), this is the RN strip's path and the fallback |
| `apps/browser/src/components/layout/frozenPage.tsx` | 53 | b | 0.4.2 | Handoff receipt/activation guards and native FrozenPageView state; also d hosting |
| `apps/browser/src/components/layout/geometry.ts` | 97 | b | 0.4.2 | Split sizing and toolbar geometry |
| `apps/browser/src/components/layout/history.ts` | 140 | b | 0.4.2 | Back/forward/history target rules; also c |
| `apps/browser/src/components/layout/measuredWidths.ts` | 32 | c | 0.4.5 | Measured-width cache |
| `apps/browser/src/components/layout/nativeDock.ts` | 77 | d | 0.4.6 | Native dock state/motion mirror |
| `apps/browser/src/components/layout/nativeLayoutFeed.ts` | 47 | b | 0.4.2 | Coalesced native layout ownership admission and state feed; also d bridge |
| `apps/browser/src/components/layout/nativePaneOverlays.ts` | 221 | d | 0.4.6 | Pane overlay/hint JSON feeds |
| `apps/browser/src/components/layout/nativeSplitChrome.ts` | 156 | d | 0.4.6 | Split JSON feeds; also b toast callback |
| `apps/browser/src/components/layout/nativeTabDrag.ts` | 58 | b | 0.4.4 | Native drag event decisions; preview capture, pictures, window haptic and glow are Swift's when native, `tabDrag.end`/`tabDrag.capture` remain for drags Swift doesn't own |
| `apps/browser/src/components/layout/openFromPage.ts` | 51 | b | 0.4.2 | Page-created tab/window routing |
| `apps/browser/src/components/layout/pageState.ts` | 127 | c | 0.4.5 | Page facts and popover store; also b |
| `apps/browser/src/components/layout/paneFeed.ts` | 69 | c | 0.4.5 | Pane presence/status caches |
| `apps/browser/src/components/layout/peekHold.ts` | 28 | b | 0.4.2 | Peek hold/dismiss rules |
| `apps/browser/src/components/layout/pinHandoff.ts` | 125 | c | 0.4.5 | Frozen-page handoff state; also b |
| `apps/browser/src/components/layout/profilePager.ts` | 230 | b | 0.4.2 | Profile pager decisions; also c/d |
| `apps/browser/src/components/layout/shellLayout.ts` | 74 | d | 0.4.6 | Shell geometry feed |
| `apps/browser/src/components/layout/shellModal.ts` | 28 | b | 0.4.2 | Modal layer/interaction policy |
| `apps/browser/src/components/layout/splitActions.ts` | 101 | b | 0.4.2 | Split creation/drop/menu decisions |
| `apps/browser/src/components/layout/splitDrop.ts` | 43 | b | 0.4.2 | Split drop hit zones |
| `apps/browser/src/components/layout/stripFolderMenu.ts` | 19 | b | 0.4.4 | Strip folder menus; Swift decides them with the native store, this is the RN strip's path and the fallback |
| `apps/browser/src/components/layout/stripGroups.ts` | 226 | b | 0.4.4 | Strip grouping/drop/menu policy; `tuckTarget` also ported (StripQuery), this copy serves the RN strip and the fallback |
| `apps/browser/src/components/layout/stripReorder.ts` | 70 | b | 0.4.4 | RN reorder motion policy |
| `apps/browser/src/components/layout/swipeMotion.ts` | 33 | b | 0.4.2 | Swipe thresholds/selection math |
| `apps/browser/src/components/layout/tabDrag.ts` | 303 | b | 0.4.4 | Drag/drop lifecycle; also c/d. `captureDragPage` is the fallback when native capture is unavailable |
| `apps/browser/src/components/layout/toasts.ts` | 23 | c | 0.4.5 | Toast/notice store; also b lifecycle |
| `apps/browser/src/components/layout/toolbarAutoHide.ts` | 81 | b | 0.4.2 | Toolbar visibility/scroll rules; also c |
| `apps/browser/src/components/layout/toolbarColors.ts` | 107 | b | 0.4.2 | Toolbar palette/motion policy |
| `apps/browser/src/components/layout/usePeek.ts` | 51 | b | 0.4.2 | Peek hover/motion decisions |
| `apps/browser/src/components/layout/useResizeDrag.ts` | 74 | b | 0.4.2 | Split resize interaction |
| `apps/browser/src/components/layout/windowDrop.ts` | 49 | b | 0.4.4 | Cross-window drag placement |
| `apps/browser/src/components/layout/windowLayout.ts` | 117 | b | 0.4.2 | Layout/address-bar selection; also c anchors |
| `apps/browser/src/components/littleSolara/LittleSolaraWindow.tsx` | 190 | b | 0.4.2 | Small-window composition; also d native bar |
| `apps/browser/src/components/littleSolara/SmallChrome.tsx` | 129 | a | 0.4.0 | RN label/progress helpers used by legacy Peek fallback, not native small bar |
| `apps/browser/src/components/littleSolara/actions.ts` | 134 | b | 0.4.2 | Small-window open/expand routing |
| `apps/browser/src/components/live/CalendarPreview.tsx` | 123 | b | 0.4.4 | Calendar grouping/labels/join policy; also d native card feed |
| `apps/browser/src/components/live/LiveItemCard.tsx` | 277 | a | 0.4.0 | Fallback live-card pixels; also b actions |
| `apps/browser/src/components/live/MeetingAlert.tsx` | 108 | b | 0.4.4 | Alert placement/join policy; native frame owns both lanes' motion; also d feed |
| `apps/browser/src/components/live/colors.ts` | 33 | d | 0.4.6 | Live badge palette |
| `apps/browser/src/components/media/CastPicker.tsx` | 92 | b | 0.4.4 | Cast target selection; also d host |
| `apps/browser/src/components/media/HoverPlayer.tsx` | 59 | d | 0.4.6 | Native hover-player placement/feed |
| `apps/browser/src/components/media/ShareBar.tsx` | 146 | b | 0.4.4 | Share controls; also d animated native placement |
| `apps/browser/src/components/media/SharePicker.tsx` | 196 | b | 0.4.4 | Screen-share selection; also d host |
| `apps/browser/src/components/media/SidebarPlayer.tsx` | 25 | b | 0.4.4 | Sidebar player eligibility/order/selection and action routing |
| `apps/browser/src/components/media/TabBadges.tsx` | 55 | a | 0.4.0 | RN PiP/capture badge fills only in React top-strip fallback |
| `apps/browser/src/components/media/artwork.ts` | 51 | c | 0.4.5 | Artwork cache and loading |
| `apps/browser/src/components/media/cast.ts` | 80 | b | 0.4.4 | Cast target/menu policy |
| `apps/browser/src/components/media/nativeMedia.tsx` | 117 | b | 0.4.4 | Media control/action policy; also d JSON host |
| `apps/browser/src/components/media/pip.ts` | 44 | b | 0.4.4 | PiP open/close policy |
| `apps/browser/src/components/media/state.ts` | 189 | c | 0.4.5 | Media session and PiP stores |
| `apps/browser/src/components/media/tokens.ts` | 1 | d | 0.4.6 | Media token re-export |
| `apps/browser/src/components/nativeDownloadsPanel.ts` | 54 | d | 0.4.6 | Native download-panel state feed with owned publisher cleanup |
| `apps/browser/src/components/nativeHostProps.ts` | 85 | d | 0.4.6 | Native host JSON shapes |
| `apps/browser/src/components/ntp/CheckInBanner.tsx` | 42 | d | 0.4.6 | Native check-in state/action bridge; no RN drawing |
| `apps/browser/src/components/ntp/NativeNewTabHero.tsx` | 75 | d | 0.4.6 | Native hero host/feed; also b navigation callbacks |
| `apps/browser/src/components/ntp/Personalize.tsx` | 64 | b | 0.4.2 | Native Personalize open/actions; also d theme/profile/layout feeds |
| `apps/browser/src/components/ntp/Postcard.tsx` | 82 | d | 0.4.6 | Native postcard/page bridge with profile/presentation receipts; no RN drawing |
| `apps/browser/src/components/ntp/index.tsx` | 30 | d | 0.4.6 | Transparent New Tab native-host composition and tour anchors |
| `apps/browser/src/components/ntp/newTabLayout.ts` | 21 | b | 0.4.2 | New Tab hero geometry |
| `apps/browser/src/components/ntp/releaseNotes.ts` | 133 | c | 0.4.5 | Release-note content/progress store and current-page receipts; also b |
| `apps/browser/src/components/omnibox/NativeOmniboxBar.tsx` | 80 | d | 0.4.6 | Native bar host/focus relay; ownership-off action fallback |
| `apps/browser/src/components/omnibox/actions.ts` | 141 | b | 0.4.2 | Command candidate eligibility/titles |
| `apps/browser/src/components/omnibox/barState.ts` | 51 | b | 0.4.2 | Bar dismissal/focus policy; also c |
| `apps/browser/src/components/omnibox/devDriver.ts` | 55 | b | 0.4.2 | Omnibox driver/trace hooks |
| `apps/browser/src/components/omnibox/dropdownStart.ts` | 47 | b | 0.4.2 | App-dead; retained for source-reading tests and native idle-tabs fixture hash; initial suggestion selection |
| `apps/browser/src/components/omnibox/extensions.ts` | 17 | c | 0.4.5 | Extension candidate projection |
| `apps/browser/src/components/omnibox/knownHosts.ts` | 30 | c | 0.4.5 | Perf/test-only history host projection; micro-bench and suggest-hermes consumers remain |
| `apps/browser/src/components/omnibox/nativeBar.tsx` | 207 | b | 0.4.2 | Ownership-off action/menu fallback and native driver/source feeds |
| `apps/browser/src/components/omnibox/newTabBar.ts` | 88 | b | 0.4.2 | New Tab bar open/close/target rules |
| `apps/browser/src/components/omnibox/open.ts` | 30 | b | 0.4.2 | Ownership-off navigation/switch disposition fallback |
| `apps/browser/src/components/omnibox/organizeActions.ts` | 154 | b | 0.4.2 | Organize-command eligibility |
| `apps/browser/src/components/omnibox/paste.ts` | 35 | b | 0.4.2 | Ownership-off clipboard URL/menu fallback; native toolbar and sidebar intercept owned URL actions |
| `apps/browser/src/components/omnibox/profileBookmarks.ts` | 20 | c | 0.4.5 | Bookmark row projection |
| `apps/browser/src/components/omnibox/runBar.ts` | 79 | b | 0.4.2 | Fallback for commands without a native owner; opening commands/extensions route through native hosts |
| `apps/browser/src/components/omnibox/workspaceSources.ts` | 101 | b | 0.4.2 | Workspace feed selection; also d |
| `apps/browser/src/components/onboarding/OnboardingOverlay.tsx` | 20 | d | 0.4.6 | Native onboarding/tour placement |
| `apps/browser/src/components/onboarding/index.ts` | 3 | d | 0.4.6 | Onboarding export facade |
| `apps/browser/src/components/onboarding/sites.ts` | 66 | b | 0.4.2 | Onboarding site/pin selection |
| `apps/browser/src/components/onboarding/state.ts` | 397 | c | 0.4.5 | Onboarding document/session state; also b |
| `apps/browser/src/components/onboarding/tour/ToolTour.tsx` | 64 | d | 0.4.6 | Native tour state/anchor feed |
| `apps/browser/src/components/onboarding/tour/anchors.ts` | 47 | d | 0.4.6 | Native tour anchor feed |
| `apps/browser/src/components/onboarding/tour/state.ts` | 104 | c | 0.4.5 | Tour progress store; also b |
| `apps/browser/src/components/overlayGates.ts` | 11 | d | 0.4.6 | Overlay owner gate helper |
| `apps/browser/src/components/pageEvents.ts` | 412 | b | 0.4.2 | Page-event handling/navigation; also c |
| `apps/browser/src/components/pages/ClearDataDialog.tsx` | 35 | b | 0.4.2 | Clear-data native invocation |
| `apps/browser/src/components/pages/InternalPage.tsx` | 38 | d | 0.4.6 | Native internal-page placement |
| `apps/browser/src/components/pages/NativeBookmarksPage.tsx` | 100 | b | 0.4.2 | Bookmark commands; also d page host |
| `apps/browser/src/components/pages/NativeDownloadsPage.tsx` | 37 | b | 0.4.2 | Download commands; also d page host |
| `apps/browser/src/components/pages/NativeHistoryPage.tsx` | 56 | b | 0.4.2 | History commands; also d page host |
| `apps/browser/src/components/pages/appUrls.ts` | 46 | b | 0.4.2 | App URL routing |
| `apps/browser/src/components/pages/devDrivers.ts` | 43 | b | 0.4.2 | Native page development driver |
| `apps/browser/src/components/pages/index.ts` | 3 | d | 0.4.6 | Internal-page export facade |
| `apps/browser/src/components/pages/internalUrls.ts` | 27 | b | 0.4.2 | Internal URL classification |
| `apps/browser/src/components/pages/nativePageTheme.ts` | 12 | d | 0.4.6 | Native page theme feed |
| `apps/browser/src/components/pages/urls.ts` | 28 | b | 0.4.2 | Internal URL/navigation routing |
| `apps/browser/src/components/peek/NativePeekMount.tsx` | 72 | b | 0.4.2 | Peek transitions; also d native state |
| `apps/browser/src/components/peek/PeekOverlay.tsx` | 239 | a | 0.4.0 | Fallback peek card/bar; also b interaction |
| `apps/browser/src/components/peek/actions.ts` | 136 | b | 0.4.2 | Peek open/close/expand routing |
| `apps/browser/src/components/peek/nativePeek.ts` | 56 | d | 0.4.6 | Native peek state feed |
| `apps/browser/src/components/peek/pinch.ts` | 17 | b | 0.4.2 | Pinch-to-peek interaction |
| `apps/browser/src/components/pooledPages.ts` | 156 | b | 0.4.2 | Pool plans/navigation reconciliation; also d |
| `apps/browser/src/components/primitives.tsx` | 143 | a | 0.4.0 | IconButton still draws RN; favicon/image/initial/New Tab adapters host native sidebar icons; also b hover |
| `apps/browser/src/components/profiles/CreateProfile.tsx` | 80 | b | 0.4.2 | Create-profile decisions; also d host |
| `apps/browser/src/components/profiles/ProfileDots.tsx` | 69 | a | 0.4.0 | Fallback RN profile-dot fills; also b switching |
| `apps/browser/src/components/profiles/icons.tsx` | 2 | b | 0.4.2 | Profile symbol-name parsing; no RN pixels |
| `apps/browser/src/components/settings/controls.tsx` | 311 | a | 0.4.0 | Live useFormColors; RN widget exports, including Checkbox, now unconsumed |
| `apps/browser/src/components/settings/native/autofill.ts` | 36 | c | 0.4.5 | Autofill resource/cache facade; also b CRUD |
| `apps/browser/src/components/settings/native/extensions.ts` | 31 | b | 0.4.2 | Extension close/open/refresh routing; also d |
| `apps/browser/src/components/settings/native/import.ts` | 438 | b | 0.4.2 | Import RPC orchestration; also c progress |
| `apps/browser/src/components/settings/native/live.ts` | 28 | b | 0.4.2 | Live-folder/OAuth/window routing |
| `apps/browser/src/components/settings/native/onboarding.ts` | 94 | b | 0.4.2 | Onboarding action routing |
| `apps/browser/src/components/settings/native/passwords.ts` | 15 | b | 0.4.2 | Password CSV import routing; also d availability |
| `apps/browser/src/components/settings/native/privacy.ts` | 46 | b | 0.4.2 | Privacy clear-data operations |
| `apps/browser/src/components/settings/native/profiles.ts` | 97 | b | 0.4.2 | Profile settings operations |
| `apps/browser/src/components/settings/native/resources.ts` | 54 | c | 0.4.5 | Async resource cache/generation tracking |
| `apps/browser/src/components/settings/native/shortcuts.ts` | 11 | d | 0.4.6 | Shortcut topic mirror |
| `apps/browser/src/components/settings/native/sync.ts` | 119 | d | 0.4.6 | Sync status/action facade; also c |
| `apps/browser/src/components/settings/nativeSettings.ts` | 116 | b | 0.4.2 | JS topic/RPC server; also d feeds |
| `apps/browser/src/components/settings/searchMatch.ts` | 135 | b | 0.4.2 | Settings query matching/ranking |
| `apps/browser/src/components/settings/searchState.ts` | 30 | c | 0.4.5 | Settings search store |
| `apps/browser/src/components/settings/settingsIndex.ts` | 573 | c | 0.4.5 | Settings search catalog |
| `apps/browser/src/components/settings/windows.ts` | 43 | b | 0.4.2 | Settings/import window routing |
| `apps/browser/src/components/sidebar/AddressBar.tsx` | 99 | d | 0.4.6 | Native sidebar address host/model/action feed; RN header/URL bodies removed |
| `apps/browser/src/components/sidebar/FolderPanel.tsx` | 83 | d | 0.4.6 | Native folder panel look feed; shows a JS-opened panel only on the fallback path |
| `apps/browser/src/components/sidebar/FolderTile.tsx` | 41 | a | 0.4.0 | RN folder mosaic layout |
| `apps/browser/src/components/sidebar/GroupPanel.tsx` | 111 | b | 0.4.4 | Group row selection, state projection and action/focus receipts; native host draws search/list/rows |
| `apps/browser/src/components/sidebar/HoverCard.tsx` | 367 | a | 0.4.0 | Fallback hover pixels; also b native routing |
| `apps/browser/src/components/sidebar/IconPicker.tsx` | 74 | b | 0.4.4 | Picker events; also d native host |
| `apps/browser/src/components/sidebar/NativeSidebar.tsx` | 412 | d | 0.4.6 | Sidebar JSON feed; also b actions, the fallback for group, folder and drop actions Swift decides with the native store |
| `apps/browser/src/components/sidebar/Overlays.tsx` | 26 | b | 0.4.4 | Overlay routing; also a child UI |
| `apps/browser/src/components/sidebar/ResizeHandle.tsx` | 27 | b | 0.4.4 | Resize gesture decisions |
| `apps/browser/src/components/sidebar/SearchTabs.tsx` | 81 | b | 0.4.4 | Search ranking; also d native feed |
| `apps/browser/src/components/sidebar/TabIcon.tsx` | 109 | a | 0.4.0 | RN favicon/engine-mark pixels |
| `apps/browser/src/components/sidebar/TabSwitcher.tsx` | 9 | d | 0.4.6 | Native switcher state feed |
| `apps/browser/src/components/sidebar/actions.ts` | 138 | b | 0.4.4 | Tab selection/rename decisions |
| `apps/browser/src/components/sidebar/cleanUpUpsell.ts` | 49 | b | 0.4.4 | Cleanup offer/dismiss rules |
| `apps/browser/src/components/sidebar/closeControl.ts` | 53 | b | 0.4.4 | Close/return-to-pin semantics; group close is Swift's with the direct-write gate, this is the fallback |
| `apps/browser/src/components/sidebar/commands.ts` | 74 | b | 0.4.4 | Sidebar command/menu enablement |
| `apps/browser/src/components/sidebar/effects.ts` | 53 | b | 0.4.4 | Sidebar/live-service startup effects |
| `apps/browser/src/components/sidebar/entries.ts` | 130 | b | 0.4.4 | Sidebar ordering/group/split queries |
| `apps/browser/src/components/sidebar/fileDrop.tsx` | 21 | b | 0.4.4 | Sidebar drop target adapter; fallback when Swift doesn't open the drop |
| `apps/browser/src/components/sidebar/groupPanelRows.ts` | 40 | b | 0.4.4 | Group search/sort rules |
| `apps/browser/src/components/sidebar/hover.ts` | 153 | b | 0.4.4 | Hover intent/hold/dismiss rules |
| `apps/browser/src/components/sidebar/hoverAim.ts` | 20 | b | 0.4.4 | Hover-card pointer intent |
| `apps/browser/src/components/sidebar/hoverMotion.ts` | 109 | b | 0.4.4 | Hover placement/motion policy |
| `apps/browser/src/components/sidebar/liveMenus.ts` | 189 | b | 0.4.4 | Live-folder/calendar menus |
| `apps/browser/src/components/sidebar/menus.ts` | 438 | b | 0.4.4 | Tab/group/sidebar menus and cleanup; the group menu is Swift's with the native store except Change Icon, Move to Bookmark Bar and the New Tab bar (`runGroupMenuChoice`) |
| `apps/browser/src/components/sidebar/movePinned.ts` | 98 | b | 0.4.4 | Pin/unpin ordering rules |
| `apps/browser/src/components/sidebar/nativeDrag.ts` | 157 | b | 0.4.4 | Native drag callbacks/drop policy; receives the native folder panel mirror (`folderPanel.state`) |
| `apps/browser/src/components/sidebar/nativeHoverCard.ts` | 297 | d | 0.4.6 | Native hover-card feed; also b kind choice |
| `apps/browser/src/components/sidebar/nativeLive.ts` | 101 | b | 0.4.4 | Live item actions; also d replica |
| `apps/browser/src/components/sidebar/nativeTabPickers.ts` | 114 | d | 0.4.6 | Native search/switcher JSON feed |
| `apps/browser/src/components/sidebar/pinnedOrder.ts` | 102 | b | 0.4.4 | Live/pinned ordering rules |
| `apps/browser/src/components/sidebar/sidebarShell.ts` | 5 | d | 0.4.6 | Native full-column capability/ownership gate |
| `apps/browser/src/components/sidebar/state.ts` | 31 | c | 0.4.5 | Sidebar hover/rename/width store |
| `apps/browser/src/components/sidebar/switcher.ts` | 108 | b | 0.4.4 | Keyboard/mouse tab-switch policy |
| `apps/browser/src/components/sidebar/tidyPinsUi.ts` | 25 | b | 0.4.4 | Tidy/undo command routing |
| `apps/browser/src/components/sidebar/tileFolderUi.ts` | 82 | b | 0.4.4 | Tile-folder menu/open/rename rules: the fallback, Swift decides them with the native store; mirrors the native panel. `folderTitle` (never called) deleted |
| `apps/browser/src/components/sidebar/tokens.ts` | 128 | d | 0.4.6 | Sidebar palette/size tokens |
| `apps/browser/src/components/site/Autofill.tsx` | 48 | a | 0.4.0 | Unused RN NetworkBadge export; requestAutofill behavior remains live |
| `apps/browser/src/components/site/DeveloperButtons.tsx` | 29 | b | 0.4.4 | Developer reload/menu actions; RN button body removed |
| `apps/browser/src/components/site/DeveloperStripes.tsx` | 22 | a | 0.4.0 | RN developer stripe image |
| `apps/browser/src/components/site/DeviceChooser.tsx` | 117 | b | 0.4.4 | Chooser state/selection/guards/actions and native body feed; RN chooser body removed |
| `apps/browser/src/components/site/EnginePrompt.tsx` | 29 | b | 0.4.4 | Engine offer/remember actions and native prompt feed; RN body removed |
| `apps/browser/src/components/site/NativePromptBody.tsx` | 97 | d | 0.4.6 | Native-only prompt placement/size/event feed, independent of toolbar/pages capabilities |
| `apps/browser/src/components/site/NativeSiteControls.tsx` | 208 | b | 0.4.4 | Site-panel decisions; also d native host |
| `apps/browser/src/components/site/Prompts.tsx` | 226 | b | 0.4.4 | Permission/password/autofill/external/popup answers and native prompt specs; RN bodies removed |
| `apps/browser/src/components/site/SelectionPopover.tsx` | 57 | b | 0.4.4 | Selection delay/search actions and native SelectionBarView state; also d hosting |
| `apps/browser/src/components/site/SiteControls.tsx` | 6 | d | 0.4.6 | Native site-panel host and close-presence adapter; RN panel removed |
| `apps/browser/src/components/site/SiteControlsParts.tsx` | 12 | d | 0.4.6 | SITE_PANEL geometry constants only; RN tiles/rows removed |
| `apps/browser/src/components/site/SiteExtensions.tsx` | 15 | b | 0.4.4 | Extension menu actions only; RN extension grid removed |
| `apps/browser/src/components/site/TranslateControls.tsx` | 30 | b | 0.4.4 | Translation language/menu actions only; RN rows/buttons removed |
| `apps/browser/src/components/site/ZoomControls.tsx` | 39 | b | 0.4.4 | Zoom actions and native panel state/placement feed; RN controls removed |
| `apps/browser/src/components/site/developerMode.ts` | 111 | b | 0.4.4 | Developer URL/reload policy; also c |
| `apps/browser/src/components/site/pageTranslator.ts` | 201 | b | 0.4.4 | Page translation execution |
| `apps/browser/src/components/site/permissions.ts` | 139 | b | 0.4.4 | Permission request/answer rules |
| `apps/browser/src/components/site/promptGuard.ts` | 41 | b | 0.4.4 | Prompt lifetime guards |
| `apps/browser/src/components/site/selection.ts` | 249 | b | 0.4.4 | Selection search/copy/open policy; also c |
| `apps/browser/src/components/site/share.ts` | 12 | b | 0.4.4 | Native share command routing |
| `apps/browser/src/components/site/translate.ts` | 258 | b | 0.4.4 | Translation state/language policy; also c |
| `apps/browser/src/legacy.ts` | 51 | c | 0.4.5 | Legacy URL/key migration |
| `apps/browser/src/lib/actions.ts` | 203 | b | 0.4.2 | Window/tab/profile action routing |
| `apps/browser/src/lib/afterFirstWindow.ts` | 31 | b | 0.4.2 | First-window task scheduling |
| `apps/browser/src/lib/appIcon.ts` | 1 | d | 0.4.6 | Bundled app icon reference |
| `apps/browser/src/lib/appIntegration.ts` | 103 | b | 0.4.2 | Native app/notification event decisions |
| `apps/browser/src/lib/bookmarkGroups.ts` | 190 | b | 0.4.2 | Bookmark-folder sidebar restoration |
| `apps/browser/src/lib/bookmarkWriter.ts` | 103 | b | 0.4.2 | Native bookmark command/receipt routing; also c projection refresh |
| `apps/browser/src/lib/bookmarks.ts` | 22 | d | 0.4.6 | Native bookmark projection subscription/reload bridge |
| `apps/browser/src/lib/chromeTabs.ts` | 157 | c | 0.4.5 | Fallback Chrome tab synchronization; also b |
| `apps/browser/src/lib/cliControl.ts` | 71 | b | 0.4.2 | CLI install/stop decisions; also c mirror |
| `apps/browser/src/lib/closeAnimated.ts` | 29 | b | 0.4.2 | Animated window-close scheduling |
| `apps/browser/src/lib/closeSnapshots.ts` | 17 | c | 0.4.5 | Window close snapshot cache |
| `apps/browser/src/lib/closeWindowDialog.ts` | 24 | b | 0.4.2 | Close confirmation decisions |
| `apps/browser/src/lib/commandCatalog.ts` | 243 | b | 0.4.2 | Command metadata/eligibility |
| `apps/browser/src/lib/commandShortcuts.ts` | 69 | b | 0.4.2 | Shortcut/menu resolution; also c |
| `apps/browser/src/lib/commands.ts` | 414 | b | 0.4.2 | Main command dispatch |
| `apps/browser/src/lib/defaultBrowserCheckIn.ts` | 43 | b | 0.4.2 | Feedback check-in eligibility |
| `apps/browser/src/lib/devHarness.ts` | 127 | b | 0.4.2 | Development command dispatch |
| `apps/browser/src/lib/developerMode.ts` | 57 | b | 0.4.2 | Developer-host policy |
| `apps/browser/src/lib/earlyNavigate.ts` | 27 | b | 0.4.2 | Early-navigation handoff policy |
| `apps/browser/src/lib/engineSignIn.ts` | 41 | b | 0.4.2 | WebKit sign-in transfer decisions |
| `apps/browser/src/lib/engines.ts` | 201 | b | 0.4.2 | Engine offer/switch/history policy; also c |
| `apps/browser/src/lib/favicons.ts` | 494 | c | 0.4.5 | Favicon cache/lookup/migration |
| `apps/browser/src/lib/focusClaims.ts` | 77 | b | 0.4.2 | Focus generation/claim policy |
| `apps/browser/src/lib/focusHandoff.ts` | 61 | b | 0.4.2 | Command focus settlement |
| `apps/browser/src/lib/history.ts` | 437 | c | 0.4.5 | History sync and legacy redaction |
| `apps/browser/src/lib/hoverShift.ts` | 151 | b | 0.4.2 | Development React layout inspection |
| `apps/browser/src/lib/jsErrors.ts` | 81 | c | 0.4.5 | JS error recording; also b fatal policy |
| `apps/browser/src/lib/keepAliveFeed.ts` | 140 | b | 0.4.2 | Keep-alive identity/epoch sequencing and resend policy; also d report relay |
| `apps/browser/src/lib/keepAwakeSites.ts` | 48 | b | 0.4.2 | Keep-awake site matching and sleep setting normalization |
| `apps/browser/src/lib/killSwitches.ts` | 111 | c | 0.4.5 | Cached switch configuration; also b defaults |
| `apps/browser/src/lib/launchBackdrop.ts` | 21 | d | 0.4.6 | Native launch-backdrop projection |
| `apps/browser/src/lib/launchLook.ts` | 112 | c | 0.4.5 | Launch appearance cache; also b fallback |
| `apps/browser/src/lib/layoutWatch.ts` | 99 | b | 0.4.2 | Layout diagnostics; also c report |
| `apps/browser/src/lib/lazyProfiles.ts` | 90 | b | 0.4.2 | Profile admission/loading orchestration; also c loaded replica |
| `apps/browser/src/lib/linkRoutes.ts` | 18 | b | 0.4.2 | External-link profile/adoption routing |
| `apps/browser/src/lib/livePage.ts` | 40 | b | 0.4.2 | Live WebView command targeting |
| `apps/browser/src/lib/memoryTrim.ts` | 45 | b | 0.4.2 | Memory compaction policy |
| `apps/browser/src/lib/native.ts` | 321 | b | 0.4.2 | Window/menu/native event decisions; also d |
| `apps/browser/src/lib/nativeEvents.ts` | 142 | d | 0.4.6 | Native report batching/relay |
| `apps/browser/src/lib/nativeKeepAlive.ts` | 165 | b | 0.4.2 | Native sleep protection/lifetime coordination; also d report feed |
| `apps/browser/src/lib/notifications.ts` | 23 | b | 0.4.2 | Notification event routing |
| `apps/browser/src/lib/opaqueCard.ts` | 15 | d | 0.4.6 | Native card color projection |
| `apps/browser/src/lib/pageHandoff.ts` | 2 | d | 0.4.6 | Handoff completion helper |
| `apps/browser/src/lib/pagesPool.ts` | 6 | d | 0.4.6 | Native pool/overlay owner gates |
| `apps/browser/src/lib/pendingUpdate.ts` | 39 | c | 0.4.5 | Pending-update mirror; also b install |
| `apps/browser/src/lib/perfMarks.ts` | 216 | b | 0.4.2 | Journey sampling; also c counters |
| `apps/browser/src/lib/perfProbe.ts` | 521 | b | 0.4.2 | React/bridge instrumentation; also c |
| `apps/browser/src/lib/persist.ts` | 441 | c | 0.4.5 | Persistence/bootstrap/migration; also b |
| `apps/browser/src/lib/persistLatch.ts` | 8 | c | 0.4.5 | Persistence refusal latch |
| `apps/browser/src/lib/pinnedLinkController.ts` | 86 | b | 0.4.2 | Pinned-link interception and disposition policy; also c pending decisions |
| `apps/browser/src/lib/pinnedLinks.ts` | 80 | b | 0.4.2 | Pinned-link source selection and target routing |
| `apps/browser/src/lib/preload.ts` | 40 | b | 0.4.2 | Engine prewarm policy |
| `apps/browser/src/lib/productName.ts` | 33 | d | 0.4.6 | Native product metadata/constants |
| `apps/browser/src/lib/profileData.ts` | 44 | c | 0.4.5 | Deleted-profile data cleanup |
| `apps/browser/src/lib/profileLoading.ts` | 52 | b | 0.4.2 | Profile launch/page target selection |
| `apps/browser/src/lib/profileTheme.ts` | 359 | b | 0.4.2 | Profile appearance selection/math; also c schema |
| `apps/browser/src/lib/profileThemeActions.ts` | 13 | b | 0.4.2 | App-dead; retained for live theme-pairing regression coverage; theme choice helper |
| `apps/browser/src/lib/scriptUrls.ts` | 10 | b | 0.4.2 | JavaScript URL admission |
| `apps/browser/src/lib/shortcuts.ts` | 115 | b | 0.4.2 | Shortcut parsing/conflict resolution |
| `apps/browser/src/lib/signInCookies.ts` | 24 | c | 0.4.5 | Cookie transfer filtering |
| `apps/browser/src/lib/siteIcons.ts` | 37 | d | 0.4.6 | Bundled site icon lookup |
| `apps/browser/src/lib/slowTimers.ts` | 111 | b | 0.4.2 | Slow-job scheduling |
| `apps/browser/src/lib/tabLifecycle.ts` | 511 | b | 0.4.2 | Discard/freeze/battery policy; also c state |
| `apps/browser/src/lib/tabPages.ts` | 66 | b | 0.4.2 | Page transfer/launch claim decisions |
| `apps/browser/src/lib/tabPictures.ts` | 61 | c | 0.4.5 | Tab screenshot cache; the fallback when Swift's TabDragPictures is off |
| `apps/browser/src/lib/tabReveal.ts` | 61 | b | 0.4.2 | Tab-reveal eligibility |
| `apps/browser/src/lib/tabSleepPolicy.ts` | 66 | b | 0.4.2 | Fallback sleep candidate and unused-profile policy |
| `apps/browser/src/lib/theme.ts` | 347 | b | 0.4.2 | Appearance/palette resolution; also d tokens |
| `apps/browser/src/lib/tileTheme.ts` | 28 | d | 0.4.6 | Theme token projection |
| `apps/browser/src/lib/timeAgo.ts` | 16 | d | 0.4.6 | Relative-time display formatter |
| `apps/browser/src/lib/useNow.ts` | 12 | b | 0.4.2 | Coalesced React clock scheduling |
| `apps/browser/src/lib/webviews.ts` | 34 | c | 0.4.5 | WebView handle registry |
| `apps/browser/src/lib/windowClose.ts` | 75 | b | 0.4.2 | Window-close decision sequencing |
| `apps/browser/src/lib/windowOpenOrder.ts` | 15 | b | 0.4.2 | Window launch ordering |
| `apps/browser/src/lib/windowSync.ts` | 113 | b | 0.4.2 | Window open/close/fullscreen policy; also d |
| `apps/browser/src/lib/windowTint.ts` | 55 | b | 0.4.2 | Window-tint tracking/motion policy |
| `apps/browser/src/live/alerts.ts` | 37 | b | 0.4.4 | Meeting join/dismiss/window selection |
| `apps/browser/src/live/calendar.ts` | 49 | d | 0.4.6 | Native calendar replica; also b clock timer |
| `apps/browser/src/live/engine.ts` | 112 | b | 0.4.4 | Live tab integration/cleanup decisions |
| `apps/browser/src/live/github.ts` | 31 | b | 0.4.4 | GitHub status/tone derivation |
| `apps/browser/src/live/googleAuth.ts` | 49 | b | 0.4.4 | OAuth tab/window lifecycle |
| `apps/browser/src/live/index.ts` | 9 | b | 0.4.4 | Starts auth/grouping/cleanup observers |
| `apps/browser/src/live/meetingGroups.ts` | 120 | b | 0.4.4 | Meeting tab/group/autogroup decisions |
| `apps/browser/src/live/meetings.ts` | 182 | b | 0.4.4 | Meeting URL/event/link matching |
| `apps/browser/src/live/sources.ts` | 11 | b | 0.4.4 | Live source/icon fallback policy |
| `apps/browser/src/live/store.ts` | 157 | d | 0.4.6 | Native live JSON replica/command facade |
| `apps/browser/src/live/types.ts` | 75 | c | 0.4.5 | Live source/item data types |
| `apps/browser/src/main.tsx` | 78 | b | 0.4.2 | Service boot; main/pane registration |
| `apps/browser/src/nativeApi.tsx` | 43 | a | 0.4.0 | Alternate skew-screen pixels; also b version gate |
| `apps/browser/src/react-native-macos.d.ts` | 10 | d | 0.4.6 | RN type declarations; no runtime |
| `apps/browser/src/store/bookmarkProjection.ts` | 102 | c | 0.4.5 | Native bookmark replica revision and write guards |
| `apps/browser/src/store/bookmarks.ts` | 154 | c | 0.4.5 | Bookmark tree model and edits; also b |
| `apps/browser/src/store/browser.ts` | 252 | c | 0.4.5 | Zustand assembly/replica; also b fallback |
| `apps/browser/src/store/changes.ts` | 22 | c | 0.4.5 | Store subscription comparison |
| `apps/browser/src/store/closedTogether.ts` | 25 | b | 0.4.4 | Reopen eligibility and order |
| `apps/browser/src/store/closingWindowRestore.ts` | 79 | c | 0.4.5 | Close snapshot remapping/undo |
| `apps/browser/src/store/closingWindows.ts` | 14 | c | 0.4.5 | Closing-window set; also d command forwarding |
| `apps/browser/src/store/draftGroups.ts` | 89 | b | 0.4.4 | Draft admission/dedupe/placement; also c |
| `apps/browser/src/store/drops.ts` | 175 | b | 0.4.4 | Drop and selection rules; also c |
| `apps/browser/src/store/engines.ts` | 154 | b | 0.4.4 | Engine choice and visit debounce; also c |
| `apps/browser/src/store/groupNames.ts` | 99 | b | 0.4.4 | Automatic group naming |
| `apps/browser/src/store/groups.ts` | 419 | b | 0.4.4 | Group creation/nesting/close rules; also c |
| `apps/browser/src/store/history.ts` | 70 | c | 0.4.5 | History state and migration |
| `apps/browser/src/store/hooks.ts` | 85 | c | 0.4.5 | Zustand/window context selectors |
| `apps/browser/src/store/launchTab.ts` | 22 | b | 0.4.4 | Early-launch tab eligibility |
| `apps/browser/src/store/liveTabs.ts` | 308 | b | 0.4.4 | Chrome reconciliation policy; also c |
| `apps/browser/src/store/model.ts` | 227 | c | 0.4.5 | State queries/types; also b selection |
| `apps/browser/src/store/nativeStore.ts` | 465 | c | 0.4.5 | Native-store replica/guards; also d dispatch |
| `apps/browser/src/store/nativeWorkspace.ts` | 176 | d | 0.4.6 | Workspace patches/effects relay |
| `apps/browser/src/store/newTabBar.ts` | 40 | b | 0.4.4 | Empty-window command-bar policy |
| `apps/browser/src/store/openers.ts` | 104 | b | 0.4.4 | New-tab placement and successor rules |
| `apps/browser/src/store/organize.ts` | 1013 | b | 0.4.4 | Selection/pin/group/cleanup rules; also c |
| `apps/browser/src/store/pageKeys.ts` | 32 | c | 0.4.5 | Page identity keys |
| `apps/browser/src/store/pageProgress.ts` | 29 | c | 0.4.5 | Page progress replica |
| `apps/browser/src/store/pageSession.ts` | 15 | c | 0.4.5 | Per-page session tracking |
| `apps/browser/src/store/parkedPins.ts` | 146 | c | 0.4.5 | Pin snapshot/adoption; also b admission |
| `apps/browser/src/store/peek.ts` | 108 | b | 0.4.4 | Peek lifecycle; also c |
| `apps/browser/src/store/pinHomes.ts` | 28 | b | 0.4.4 | Pinned-home policy |
| `apps/browser/src/store/pinMirror.ts` | 397 | b | 0.4.4 | Cross-window pin rules; also c |
| `apps/browser/src/store/pinOrderChoices.ts` | 61 | c | 0.4.5 | Pinned-order choice records |
| `apps/browser/src/store/pinShare.ts` | 260 | b | 0.4.4 | Pinned-page sharing/handoff; also c |
| `apps/browser/src/store/pinnedArea.ts` | 122 | c | 0.4.5 | Pinned-area state transforms |
| `apps/browser/src/store/profiles.ts` | 236 | c | 0.4.5 | Profile identity/data lifecycle; also b |
| `apps/browser/src/store/safeLibraryEdits.ts` | 29 | c | 0.4.5 | Bookmark edit safety state |
| `apps/browser/src/store/settings.ts` | 373 | c | 0.4.5 | Settings schema/defaults; also b policy |
| `apps/browser/src/store/sidebarRail.ts` | 66 | b | 0.4.4 | Sidebar width and per-window override policy; also d native commands |
| `apps/browser/src/store/small.ts` | 46 | b | 0.4.4 | Little Solara targeting; also c |
| `apps/browser/src/store/splits.ts` | 342 | b | 0.4.4 | Pane creation/focus/layout rules; also c |
| `apps/browser/src/store/structure.ts` | 36 | c | 0.4.5 | Workspace structure transforms |
| `apps/browser/src/store/syncOrigin.ts` | 22 | c | 0.4.5 | Sync-origin transaction marker |
| `apps/browser/src/store/tabShare.ts` | 354 | b | 0.4.4 | Shared-tab rules; also c |
| `apps/browser/src/store/tabWatch.ts` | 86 | c | 0.4.5 | Tab state subscriptions |
| `apps/browser/src/store/tabs.ts` | 536 | b | 0.4.4 | Tab open/close/navigation rules; also c |
| `apps/browser/src/store/tidyPins.ts` | 153 | b | 0.4.4 | Pinned grouping policy |
| `apps/browser/src/store/tileFolders.ts` | 171 | b | 0.4.4 | Tile-folder semantics; also c |
| `apps/browser/src/store/transaction.ts` | 50 | c | 0.4.5 | State transaction boundaries |
| `apps/browser/src/store/types.ts` | 213 | c | 0.4.5 | Browser-state types; no runtime |
| `apps/browser/src/store/ui.ts` | 135 | b | 0.4.4 | Panel/focus/download behavior; also c |
| `apps/browser/src/store/windows.ts` | 535 | b | 0.4.4 | Window lifecycle and restore rules; also c |
| `apps/browser/src/sync/adapters.ts` | 772 | c | 0.4.5 | Settings/profile/library sync adapters |
| `apps/browser/src/sync/commandJournal.ts` | 58 | c | 0.4.5 | App-dead; retained as live native-store/sync-origin test oracle |
| `apps/browser/src/sync/editJournal.ts` | 121 | c | 0.4.5 | Durable edit journal |
| `apps/browser/src/sync/engine.ts` | 2397 | c | 0.4.5 | Sync orchestration/persistence; also b |
| `apps/browser/src/sync/extensions.ts` | 110 | c | 0.4.5 | Extension sync reconciliation |
| `apps/browser/src/sync/fixtures/pinned-v0.2.38.ts` | 184 | c | 0.4.5 | Historical pin fixture; non-test filename |
| `apps/browser/src/sync/fixtures/pinned-v0.2.40.ts` | 507 | c | 0.4.5 | Historical pin fixture; non-test filename |
| `apps/browser/src/sync/journalHost.ts` | 194 | c | 0.4.5 | Journal state host |
| `apps/browser/src/sync/ledgerPasswords.ts` | 313 | c | 0.4.5 | Password-ledger sync adapter |
| `apps/browser/src/sync/menu.ts` | 33 | b | 0.4.2 | Sync device/tab menu choices |
| `apps/browser/src/sync/notes.ts` | 14 | c | 0.4.5 | Sync note/state records |
| `apps/browser/src/sync/pairingBootstrap.ts` | 109 | c | 0.4.5 | Pairing document bootstrap |
| `apps/browser/src/sync/pairingNative.ts` | 54 | b | 0.4.2 | Pairing startup/retry coordination; also c |
| `apps/browser/src/sync/passwordLedger.ts` | 178 | c | 0.4.5 | Password-ledger state |
| `apps/browser/src/sync/pinned.ts` | 931 | c | 0.4.5 | Pin extraction/merge; native apply |
| `apps/browser/src/sync/readable.ts` | 33 | c | 0.4.5 | Readable sync state serialization |
| `apps/browser/src/sync/redesignSwitch.ts` | 1 | d | 0.4.6 | Native sync-launch gate mirror |
| `apps/browser/src/sync/stateDeltas.ts` | 129 | c | 0.4.5 | Sync delta generation/replay |

### Bookmark ownership cutover (0.3.0)

NativeBookmarkLaunch installs one process owner before catalog observation. BookmarkCoordinator owns durable
desired state and edit facts; BookmarkPump alone reads/applies Chrome. The JS bookmark service subscribes to
native projection and refreshes after receipts. Its watcher, push/retry, migration and cache writer are retired,
as are the production JS bookmark reducers and sync replacement fallback. Pure mapping/readers and historical
test oracles remain. Cycle, transport, encryption and HLC minting stay in JS.

Safe mode retains the claimed native display with a notice, read-only journal decoding and no edits or sync.
Development-off/partial scope fails closed. API 40 and bookmark bridge version 3 require a rebuilt native host.

### Layout-port Patch 11 ownership and retained-caller audit

API 64 enables native window layout by default. `App.tsx` uses native window bounds for feature overlays;
`ContentCard.tsx` has no page renderer, split rectangles, measured layout host, page-top publisher or dock animation.
`nativeWindowAnchors.ts` only receives native geometry. `nativeDockEvents.ts` only receives native presentation
events used by hover and feature actions. Neither mounts a layout host or publishes geometry.

No RN file, Expo module registration or native bridge is deleted by this patch: the following live callers
prevent removing the complete legacy path and feature adapters. Source-audit tests check the two entry paths;
`native-layout-default-test.mjs` is the default-candidate runtime ownership/pool/blocker gate.

| Retained machinery | Live callers and reason |
| --- | --- |
| `LegacyWindow.tsx`, `layout/SidebarDock.tsx`, `layout/TopTabStrip.tsx`, `Sidebar.tsx` | Explicit development/prerequisite-off or workspace-off browser composition; dock, strip, side-panel spacer and measurements run together only on that path. |
| `LegacyContentCard.tsx`, `layout/{geometry,shellLayout,SplitChrome,toolbarAutoHide}.ts*` | `ContentCard` selects the complete legacy card; `LittleSolaraWindow` uses that selector. Inline/unpooled pages still need their renderer, geometry and gestures. |
| `PaneContent.tsx`, `ContentServices.ts` | `PaneRoot` registers `pane`; the default card's native fallback slot also mounts the same feature guest. New Tab, internal pages, overlays and page/action services remain live. The pane-root pool prerequisite stays. |
| `sidebar.shell`, `sidebar.dock`, hosted sidebar/strip factories and `setLayout` | The legacy dock/sidebar/strip wrappers still publish them; native factories and module methods still serve that complete path. Native owners reject legacy layout publications. |
| `split.theme`, `split.toolbar`, pane overlay/pool/fallback methods | Native theme/action feeds and remaining feature guests still call them; legacy mode additionally supplies page tops/presentation. These are not obsolete registrations. |
| `peek.state`, `NativePeekMount`, `peekHold`, frozen-page adapters | Still used on the default path pending Patch 9. Deleting them here would remove Peek or reveal holds. Patch 9 must update the new native card and extracted legacy/feature consumers separately. |

Fallback matrix: default regular/private windows use native layout and the pool; safe mode retains that layout
and its existing restore/extension policy. Development `SOLARA_NATIVE_WINDOW_LAYOUT=0`, any disabled required
layout/pool prerequisite, `SOLARA_TAB_POOL=0`, or workspace-off uses the complete legacy browser/card path.
Little Solara keeps its separate host and unpooled legacy card. Sidebar-side controls remain unavailable on an
incapable path. Distribution ignores environment overrides for shipped default-on switches. Shell descriptions
and launch logs report a legacy-path reason. Neither fallback nor default runtime matrix is claimed passed here.

`apps/browser/src/LegacyWindow.tsx`: 71 lines, d, 0.4.6 — Complete legacy browser composition for documented fallbacks.

`apps/browser/src/components/LegacyContentCard.tsx`: 604 lines, b, 0.4.2 — Complete legacy page renderer and split/dock geometry; active small-window fill, clipping and content sizing use a native container.

`apps/browser/src/components/PaneContent.tsx`: 186 lines, a, 0.4.0 — Feature-only native-slot guest and overlay adapters; no browser layout owner.

`apps/browser/src/components/ContentServices.ts`: 16 lines, b, 0.4.2 — Page, permission, selection, media and Peek service starters.

`apps/browser/src/components/layout/nativeWindowAnchors.ts`: 38 lines, d, 0.4.6 — Generation-fenced native geometry intake.

`apps/browser/src/components/layout/nativeDockEvents.ts`: 18 lines, d, 0.4.6 — Native presentation event intake for feature actions.

### 0.4.2 small-window, calendar/meeting and side-panel drawing audit

Little Solara's active native shell now selects `SmallWindowPageHost` through the existing
`littleSolaraShellActive` check. `SmallWindowCardView` supplies its translucent fill and the native host clips
and sizes the content. The RN rounded clip/background is absent on that lane; the complete legacy lane retains
it. The existing unpooled engine page remains in the same subtree with its session, props and events unchanged;
this port does not create a second page, reparent it or take over its disposal. RN retains transparent window
placement and page/action state feeds.

Calendar bodies already draw through `NativePage`/`LiveCardView` and the native hover path through
`SidebarCalendarCardView`/`CalendarPreviewCard`; the fallback `HoverSurface` uses native `Surface` fill,
border and shadow. `SidebarMeetingCountdown` already draws and animates natively. Both native-shell and inline
fallback meeting alerts now use `MeetingAlertFrameView`; the fallback RN wrapper only supplies position/width.

The extension panel was already native throughout: `ExtensionSidePanelView` draws header, chrome, grip and
white empty/loading content; `SidePanelHost` directly owns the standalone engine page. `SidePanel.tsx` projects
state and actions and returns null; its legacy room spacer is transparent. Native tests cover theme/layout,
page reuse, replaced-page event fencing, empty-state identity and release after exit settles.

Swift layout/state coverage and the Little Solara driver's native-host expectations are prepared. Pass 3
passed in the build VM: side-panel 37/37 and Little Solara 12/12. No app, Swift tests, host harnesses or runtime
drivers ran on the owner's Mac; rebased VM and matched visual checks are pending.
The job report lists exact commands and measurements. This is not a claim that all retained fallback RN drawing
elsewhere in the inventory has been removed.

`apps/browser/src/components/SmallWindowCard.tsx`: 14 lines, d, 0.4.6 — Native small-window card container selector and state projection; legacy lane returns its original View.

The 0.4.2 omnibox action owner is `OmniboxActionController` with `SolaraStore/OmniboxActions.swift`; both native field hosts decorate the same model events. Swift `SolaraOmnibox` already parses and ranks input. `NativeOmniboxActions` owns AppKit clipboard/context menus, address clicks, Developer Mode submission, file selection and opening Command Bar surfaces. Nonopening commands without native menu owners retain their explicit JS fallback. The disabled-JS acceptance driver is `apps/browser/scripts/native-omnibox-actions-test.mjs`; compilation and VM acceptance remain pending.

### 0.4.9 row 3 source drafts

Media preferences: `media/pip.ts` no longer reads the mirror to synchronize global
auto-PiP/upscaling settings. NativeMediaPreferences owns this feed and the existing
display-media picker enablement. The visible-page hook and remaining media stores
are still JS. Row acceptance remains pending; historical totals above are unchanged.

Extension search refresh: `extensions/searchEngines.ts` is deleted. Native notifications,
debounce/reread, parsing, merging and settings writes replace its store subscription
and mirror read. The extension catalog still supplies initial/change-driven listing;
its JS store, popup, install and side-panel ownership remain for subsequent slices.

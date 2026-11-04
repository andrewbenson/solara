import type { BrowserCommand } from "@solara/shell";
import { PRODUCT } from "./productName";
import { parseShortcut, type ShortcutSource } from "./shortcuts";

type Keys = readonly string[];
type Scope = "page" | "window";
type InLittleSolara = "page" | "off";
type Variant = { title?: string; barTitle?: string; symbol?: string; keys?: Keys };
type CommandSpec = Variant & {
  scope?: Scope;
  onInternalPages?: true;
  littleSolara?: InLittleSolara;
  variants?: Readonly<Record<string, Variant>>;
};

const inWindow = { scope: "window" } as const;
const pageInLittleSolara = { scope: "page", littleSolara: "page" } as const;
const offInLittleSolara = { littleSolara: "off" } as const;
const windowOffInLittleSolara = { scope: "window", littleSolara: "off" } as const;

export const COMMANDS: Readonly<Record<BrowserCommand, CommandSpec>> = {
  newTab: { title: "New Tab", symbol: "plus", keys: ["⌘T"] },
  newWindow: { title: "New Window", symbol: "macwindow", keys: ["⌘N"] },
  newIncognitoWindow: { title: "New Incognito Window", symbol: "eyeglasses", keys: ["⇧⌘N"] },
  newLittleSolara: { title: `New Little ${PRODUCT} Window`, keys: ["⌥⌘N"] },
  toggleOpenLinksInLittleSolara: { title: "Open Links from Other Apps in Main Window" },
  reopenClosedTab: { title: "Reopen Closed Tab", symbol: "arrow.uturn.backward", keys: ["⇧⌘T"], littleSolara: "page" },
  reopenClosedWindow: { title: "Reopen Closed Window" },
  restoreClosed: { littleSolara: "page" },
  focusCommandBar: { title: "Open Command Bar", keys: ["⌘L", "⌃F5"], ...inWindow },
  closeTab: { title: "Close Tab", symbol: "xmark", keys: ["⌘W"], ...inWindow },
  closeAllTabs: { title: "Close All Tabs", symbol: "xmark.square", keys: ["⇧⌘K"], ...windowOffInLittleSolara },
  print: { title: "Print…", symbol: "printer", keys: ["⌘P"], ...pageInLittleSolara },
  copyUrl: { title: "Copy URL", symbol: "link", keys: ["⇧⌘C"], ...pageInLittleSolara, onInternalPages: true },
  copyUrlAsMarkdown: { title: "Copy URL as Markdown", symbol: "link", keys: ["⌥⇧⌘C"], ...pageInLittleSolara, onInternalPages: true },
  findInPage: { title: "Find…", barTitle: "Find in Page", symbol: "text.magnifyingglass", keys: ["⌘F"], ...pageInLittleSolara },
  findNext: { title: "Find Next", keys: ["⌘G"], ...pageInLittleSolara },
  findPrevious: { title: "Find Previous", keys: ["⇧⌘G"], ...pageInLittleSolara },
  setAppearance: {
    variants: {
      auto: { title: "Automatic", barTitle: "Use System Appearance", symbol: "circle.lefthalf.filled" },
      light: { title: "Light", barTitle: "Light Appearance", symbol: "sun.max" },
      dark: { title: "Dark", barTitle: "Dark Appearance", symbol: "moon" },
    },
  },
  reload: { title: "Refresh", barTitle: "Reload Page", symbol: "arrow.clockwise", keys: ["⌘R"], ...pageInLittleSolara },
  forceReload: { title: "Force Refresh the Page", barTitle: "Force Reload Page", symbol: "arrow.clockwise", keys: ["⇧⌘R"], ...pageInLittleSolara },
  toggleTabLayout: { title: "Show Tabs in Sidebar", keys: ["⇧⌘S"], ...windowOffInLittleSolara },
  toggleSidebar: { title: "Auto-Hide Tabs", symbol: "sidebar.left", keys: ["⌘S", "⇧⌘L", "⇧⌘F"], ...windowOffInLittleSolara },
  openSplitPane: { title: "Open Split Pane", keys: ["⌃⇧=", "⌃+"], ...windowOffInLittleSolara },
  useSelectionForFind: { title: "Use Selection for Find", keys: ["⌘E"], ...pageInLittleSolara },
  findAndReplace: { title: "Find and Replace…", keys: ["⌥⌘F"], ...pageInLittleSolara },
  jumpToSelection: { title: "Jump to Selection", keys: ["⌘J"], ...pageInLittleSolara },
  focusNextPane: { title: "Focus Next Split Pane", keys: ["⌃⇧]", "⌃}"], ...offInLittleSolara },
  focusPreviousPane: { title: "Focus Previous Split Pane", keys: ["⌃⇧[", "⌃{"], ...offInLittleSolara },
  toggleFullUrl: { title: "Show Full URL", symbol: "text.alignleft" },
  toggleJavaScriptFromAppleEvents: { title: "Allow JavaScript from Apple Events" },
  toggleAddressBar: { title: "Show Address Bar in Sidebar", ...offInLittleSolara },
  toggleSidebarIconsOnly: { title: "Icons-Only Sidebar", symbol: "sidebar.squares.left", ...offInLittleSolara },
  cast: { title: "Cast…", littleSolara: "page" },
  zoomReset: { title: "Zoom to Actual Size", barTitle: "Actual Size", symbol: "1.magnifyingglass", keys: ["⌘0"], ...pageInLittleSolara },
  zoomIn: { title: "Zoom In", symbol: "plus.magnifyingglass", keys: ["⌘+", "⌘="], ...pageInLittleSolara },
  zoomOut: { title: "Zoom Out", symbol: "minus.magnifyingglass", keys: ["⌘-"], ...pageInLittleSolara },
  devTools: { title: "Developer Tools", symbol: "hammer", keys: ["⌥⌘I"], ...pageInLittleSolara },
  toggleDeveloperMode: { title: "Turn on Developer Mode for this site", symbol: "hammer", ...pageInLittleSolara },
  toggleDevTools: { title: "Toggle Developer Tools", keys: ["F12"], ...pageInLittleSolara },
  javaScriptConsole: { title: "JavaScript Console", keys: ["⌥⌘J"], ...pageInLittleSolara },
  inspectElements: { title: "Inspect Elements", keys: ["⌥⌘C"], ...pageInLittleSolara },
  viewSource: { title: "View Source", keys: ["⌥⌘U"], ...pageInLittleSolara },
  back: { title: "Go Back", keys: ["⌘[", "⌘←"], scope: "window", littleSolara: "page" },
  forward: { title: "Go Forward", keys: ["⌘]", "⌘→"], scope: "window", littleSolara: "page" },
  nextTab: { title: "Next Tab", keys: ["⇧⌘]", "⌘}", "⌃⇟", "⌥⌘↓"], ...windowOffInLittleSolara },
  previousTab: { title: "Previous Tab", keys: ["⇧⌘[", "⌘{", "⌃⇞", "⌥⌘↑"], ...windowOffInLittleSolara },
  selectTab: {
    ...windowOffInLittleSolara,
    variants: Object.fromEntries([1, 2, 3, 4, 5, 6, 7, 8].map((n) => [String(n), { title: `Select Tab ${n}`, keys: [`⌘${n}`] }])),
  },
  selectLastTab: { title: "Select Last Tab", keys: ["⌘9"], ...windowOffInLittleSolara },
  togglePin: {
    title: "Move to Top Apps",
    symbol: "pin",
    ...windowOffInLittleSolara,
    variants: { tile: { title: "Move Pinned Tab to Top Apps" } },
  },
  togglePinnedRow: { title: "Move to Pinned", keys: ["⌘D"], ...windowOffInLittleSolara },
  duplicateTab: { title: "Duplicate", barTitle: "Duplicate Tab", symbol: "plus.square.on.square", ...windowOffInLittleSolara },
  moveTabToProfile: windowOffInLittleSolara,
  moveTabToWindow: windowOffInLittleSolara,
  bookmarkPage: { title: "Add to Bookmarks…", symbol: "bookmark", keys: ["⌥⇧⌘D"], ...pageInLittleSolara, onInternalPages: true },
  addBookmarkToFolder: { ...pageInLittleSolara, onInternalPages: true },
  openBookmark: { scope: "window", littleSolara: "page" },
  addFolderToSidebar: {},
  restoreArcFolders: {},
  toggleMute: { title: "Mute Site", symbol: "speaker.slash", ...pageInLittleSolara },
  togglePageEngine: { title: "Open Page in WebKit" },
  downloads: { title: "Downloads", symbol: "arrow.down.circle", keys: ["⇧⌘J", "⌥⌘L"], scope: "window", littleSolara: "page" },
  mergeAllWindows: { title: "Merge All Windows", symbol: "rectangle.stack", ...windowOffInLittleSolara },
  switchProfile: inWindow,
  nextProfile: { title: "Next Profile", keys: ["⌥⌘→"], ...inWindow },
  previousProfile: { title: "Previous Profile", keys: ["⌥⌘←"], ...inWindow },
  newProfile: { title: "New Profile…", symbol: "person.crop.circle.badge.plus" },
  openSettings: { title: "Settings…", symbol: "gearshape", keys: ["⌘,"] },
  importBrowserData: { title: "Import from Another Browser…", barTitle: "Import Browser Data", symbol: "square.and.arrow.down" },
  showHistory: { title: "Show History…", barTitle: "History", symbol: "clock", keys: ["⌘Y"] },
  clearBrowsingData: { title: "Clear Browsing Data…", symbol: "trash", keys: ["⇧⌘⌫"] },
  manageBookmarks: { title: "Manage Bookmarks", barTitle: "Bookmarks", symbol: "book", keys: ["⌥⌘B"] },
  bookmarkAllTabs: { title: "Bookmark All Tabs…", keys: ["⇧⌘D"], ...offInLittleSolara },
  setBookmarksBar: { variants: { always: { title: "Always" }, newTab: { title: "On New Tab Only" }, never: { title: "Never" } } },
  toggleBookmarksBar: { title: "Toggle Bookmarks Bar", symbol: "menubar.rectangle", keys: ["⇧⌘B"] },
  newTabInGroup: { title: "New Tab in Group", keys: ["⌥⌘T", "⌃⌘C"], ...windowOffInLittleSolara },
  newGroupWithTabs: { title: "New Group with Tab", symbol: "folder.badge.plus", keys: ["⌃⌘N", "⌃⌘P"], ...windowOffInLittleSolara },
  cleanUpTabs: { title: "Clean Up Tabs", symbol: "sparkles", keys: ["⌥⌘K"], ...windowOffInLittleSolara },
  tidyPins: { title: "Tidy Pins", symbol: "sparkles" },
  searchTabs: { title: "Search Tabs…", symbol: "magnifyingglass", keys: ["⇧⌘A"], ...windowOffInLittleSolara },
  renameTab: { title: "Rename…", barTitle: "Rename Tab", symbol: "pencil", ...windowOffInLittleSolara },
  changeTabIcon: { title: "Change Icon…", ...windowOffInLittleSolara },
  returnToPinnedUrl: { title: "Back to Pinned URL", keys: ["⌘↩"], ...windowOffInLittleSolara },
  tabSwitcher: {
    ...windowOffInLittleSolara,
    variants: {
      forward: { title: "Tab Switcher (forward)", keys: ["⌃⇥"] },
      backward: { title: "Tab Switcher (backward)", keys: ["⌃⇧⇥"] },
    },
  },
  share: { title: "Share…", barTitle: "Share", symbol: "square.and.arrow.up", keys: ["⌥⌘S"], ...pageInLittleSolara },
  sendFeedback: { title: "Send Feedback…", keys: ["⌥⇧⌘I"] },
  keyboardShortcuts: { title: "Keyboard Shortcuts", symbol: "keyboard" },
  copyDiagnostics: { title: "Copy Diagnostics" },
  recordPerformanceIssue: { title: "Record Performance Issue…" },
  toolTour: { title: "Tool Tour" },
  videoTour: { title: "Video Tour" },
  releaseNotes: { title: "Release Notes" },
  showOnboarding: { title: "Show Onboarding" },
  taskManager: { title: "Task Manager" },
  openExtension: { littleSolara: "page" },
  addExtension: { title: "Add Extension…", littleSolara: "page" },
  manageExtensions: { title: "Manage Extensions…" },
  pinExtensions: { title: "Pin Extensions…" },
  autofill: {
    littleSolara: "page",
    variants: { contact: { title: "Contact…" }, passwords: { title: "Passwords…" }, creditCard: { title: "Credit Card…" } },
  },
  openFile: { title: "Open File…", keys: ["⌘O"] },
  savePage: { title: "Save Page As…", ...pageInLittleSolara },
  emailPageLocation: { title: "Email Page Location", keys: ["⇧⌘I"], ...pageInLittleSolara },
  printWithSystemDialog: { title: "Print Using System Dialog…", keys: ["⌥⌘P"], ...pageInLittleSolara },
  stop: { title: "Stop", keys: ["⌘."], ...pageInLittleSolara },
  caretBrowsing: { title: "Caret Browsing", keys: ["F7"], ...pageInLittleSolara },
  moveTabDown: { title: "Move Tab Down", keys: ["⌃⇧⇟"], ...windowOffInLittleSolara },
  moveTabUp: { title: "Move Tab Up", keys: ["⌃⇧⇞"], ...windowOffInLittleSolara },
  closeTabGroup: { title: "Close Group", keys: ["⌃⌘W"], ...windowOffInLittleSolara },
  openProfileMenu: { title: "Show Profiles Menu", keys: ["⇧⌘M"], ...inWindow },
};

export const STANDARD_ITEMS: Readonly<Record<string, { keys?: Keys }>> = {
  "std:quit:": { keys: ["⌘Q"] },
  "std:hide:": { keys: ["⌘H"] },
  "std:hideOtherApplications:": { keys: ["⌥⌘H"] },
  "std:unhideAllApplications:": {},
  "std:closeWindow:": { keys: ["⇧⌘W"] },
  "std:undo:": { keys: ["⌘Z"] },
  "std:redo:": { keys: ["⇧⌘Z"] },
  "std:cut:": { keys: ["⌘X"] },
  "std:copy:": { keys: ["⌘C"] },
  "std:paste:": { keys: ["⌘V"] },
  "std:pasteAndMatchStyle:": { keys: ["⇧⌘V"] },
  "std:delete:": {},
  "std:selectAll:": { keys: ["⌘A"] },
  "std:showGuessPanel:": { keys: ["⌘:"] },
  "std:checkSpelling:": { keys: ["⌘;"] },
  "std:toggleContinuousSpellChecking:": {},
  "std:toggleGrammarChecking:": {},
  "std:toggleAutomaticSpellingCorrection:": {},
  "std:orderFrontSubstitutionsPanel:": {},
  "std:toggleSmartInsertDelete:": {},
  "std:toggleAutomaticQuoteSubstitution:": {},
  "std:toggleAutomaticDashSubstitution:": {},
  "std:toggleAutomaticLinkDetection:": {},
  "std:toggleAutomaticDataDetection:": {},
  "std:toggleAutomaticTextReplacement:": {},
  "std:uppercaseWord:": {},
  "std:lowercaseWord:": {},
  "std:capitalizeWord:": {},
  "std:startSpeaking:": {},
  "std:stopSpeaking:": {},
  "std:toggleFullScreen:": { keys: ["🌐F", "⌃⌘F"] },
  "std:performMiniaturize:": { keys: ["⌘M"] },
  "std:miniaturizeAll:": { keys: ["⌥⌘M"] },
  "std:performZoom:": {},
  "std:arrangeWindowsInFront:": {},
  "std:toggleKeepOnTop:": {},
};

const ALL_COMMANDS = Object.keys(COMMANDS) as BrowserCommand[];
const commandsWhere = (test: (spec: CommandSpec) => boolean) => ALL_COMMANDS.filter((command) => test(COMMANDS[command]));

export const PAGE_COMMANDS = commandsWhere((c) => c.scope === "page");
export const PAGE_COMMANDS_OFF_INTERNAL_PAGES = commandsWhere((c) => c.scope === "page" && !c.onInternalPages);
export const WINDOW_COMMANDS = commandsWhere((c) => c.scope !== undefined);
export const LITTLE_SOLARA_DISABLED_COMMANDS = commandsWhere((c) => c.littleSolara === "off");
export const LITTLE_SOLARA_PAGE_COMMANDS: ReadonlySet<string> = new Set(commandsWhere((c) => c.littleSolara === "page"));

const variantOf = (command: BrowserCommand, arg: string | undefined): Variant => {
  const spec = COMMANDS[command];
  return (arg && spec.variants?.[arg]) || spec;
};

export function commandBarTitle(command: BrowserCommand, arg?: string): string {
  const { barTitle, title = "" } = variantOf(command, arg);
  return barTitle ?? title.replace(/…$/, "");
}

export const commandSymbol = (command: BrowserCommand, arg?: string): string | undefined => variantOf(command, arg).symbol ?? COMMANDS[command].symbol;

const PROFILE_SHORTCUT_COUNT = 9;
const OVERRIDABLE_PER_ITEM_COMMANDS: readonly BrowserCommand[] = ["openExtension"];

const source = (id: string, keys: Keys = []): ShortcutSource => ({ id, keys: keys.map(parseShortcut) });

export function staticShortcutSources(): ShortcutSource[] {
  const sources: ShortcutSource[] = [];
  for (const command of ALL_COMMANDS) {
    const spec = COMMANDS[command];
    sources.push(source(command, spec.keys));
    for (const [arg, variant] of Object.entries(spec.variants ?? {})) sources.push(source(`${command}:${arg}`, variant.keys));
  }
  for (const [id, item] of Object.entries(STANDARD_ITEMS)) sources.push(source(id, item.keys));
  return sources;
}

const STATIC_SOURCES = staticShortcutSources();

export function shortcutSources(profileIds: readonly string[], overriddenIds: readonly string[]): ShortcutSource[] {
  const perItem = overriddenIds.filter((id) => OVERRIDABLE_PER_ITEM_COMMANDS.some((command) => id.startsWith(`${command}:`)));
  return [
    ...STATIC_SOURCES,
    ...profileIds.flatMap((id, i) => [
      source(`switchProfile:${id}`, i < PROFILE_SHORTCUT_COUNT ? [`⌃${i + 1}`] : []),
      source(`newLittleSolara:${id}`),
    ]),
    ...perItem.map((id) => source(id)),
  ];
}

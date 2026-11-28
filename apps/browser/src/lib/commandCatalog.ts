import type { BrowserCommand } from "@solara/shell";
import { PRODUCT } from "./productName";

type Variant = { title?: string; barTitle?: string; symbol?: string };
type CommandSpec = Variant & {
  littleSolara?: "page";
  variants?: Readonly<Record<string, Variant>>;
};

export const COMMANDS: Readonly<Record<BrowserCommand, CommandSpec>> = {
  newTab: { title: "New Tab", symbol: "plus" },
  newWindow: { title: "New Window", symbol: "macwindow" },
  newIncognitoWindow: { title: "New Incognito Window", symbol: "eyeglasses" },
  newLittleSolara: { title: `New Little ${PRODUCT} Window` },
  toggleOpenLinksInLittleSolara: { title: "Open Links from Other Apps in Main Window" },
  reopenClosedTab: { title: "Reopen Closed Tab", symbol: "arrow.uturn.backward", littleSolara: "page" },
  reopenClosedWindow: { title: "Reopen Closed Window" },
  restoreClosed: { littleSolara: "page" },
  focusCommandBar: { title: "Open Command Bar" },
  closeTab: { title: "Close Tab", symbol: "xmark" },
  closeAllTabs: { title: "Close All Tabs", symbol: "xmark.square" },
  print: { title: "Print…", symbol: "printer", littleSolara: "page" },
  copyUrl: { title: "Copy URL", symbol: "link", littleSolara: "page" },
  copyUrlAsMarkdown: { title: "Copy URL as Markdown", symbol: "link", littleSolara: "page" },
  findInPage: { title: "Find…", barTitle: "Find in Page", symbol: "text.magnifyingglass", littleSolara: "page" },
  findNext: { title: "Find Next", littleSolara: "page" },
  findPrevious: { title: "Find Previous", littleSolara: "page" },
  setAppearance: {
    variants: {
      auto: { title: "Automatic", barTitle: "Use System Appearance", symbol: "circle.lefthalf.filled" },
      light: { title: "Light", barTitle: "Light Appearance", symbol: "sun.max" },
      dark: { title: "Dark", barTitle: "Dark Appearance", symbol: "moon" },
    },
  },
  reload: { title: "Refresh", barTitle: "Reload Page", symbol: "arrow.clockwise", littleSolara: "page" },
  forceReload: { title: "Force Refresh the Page", barTitle: "Force Reload Page", symbol: "arrow.clockwise", littleSolara: "page" },
  setSidebarPosition: {
    variants: {
      left: { title: "Left", barTitle: "Sidebar on Left", symbol: "sidebar.left" },
      right: { title: "Right", barTitle: "Sidebar on Right", symbol: "sidebar.right" },
    },
  },
  toggleTabLayout: { title: "Show Tabs in Sidebar" },
  toggleSidebar: { title: "Auto-Hide Tabs", symbol: "sidebar.left" },
  openSplitPane: { title: "Open Split Pane" },
  useSelectionForFind: { title: "Use Selection for Find", littleSolara: "page" },
  findAndReplace: { title: "Find and Replace…", littleSolara: "page" },
  jumpToSelection: { title: "Jump to Selection", littleSolara: "page" },
  focusNextPane: { title: "Focus Next Split Pane" },
  focusPreviousPane: { title: "Focus Previous Split Pane" },
  toggleFullUrl: { title: "Show Full URL", symbol: "text.alignleft" },
  toggleJavaScriptFromAppleEvents: { title: "Allow JavaScript from Apple Events" },
  toggleAddressBar: { title: "Show Address Bar in Sidebar" },
  toggleSidebarIconsOnly: { title: "Icons-Only Sidebar", symbol: "sidebar.squares.left" },
  cast: { title: "Cast…", littleSolara: "page" },
  zoomReset: { title: "Zoom to Actual Size", barTitle: "Actual Size", symbol: "1.magnifyingglass", littleSolara: "page" },
  zoomIn: { title: "Zoom In", symbol: "plus.magnifyingglass", littleSolara: "page" },
  zoomOut: { title: "Zoom Out", symbol: "minus.magnifyingglass", littleSolara: "page" },
  devTools: { title: "Developer Tools", symbol: "hammer", littleSolara: "page" },
  toggleDeveloperMode: { title: "Turn on Developer Mode for this site", symbol: "hammer", littleSolara: "page" },
  toggleDevTools: { title: "Toggle Developer Tools", littleSolara: "page" },
  javaScriptConsole: { title: "JavaScript Console", littleSolara: "page" },
  inspectElements: { title: "Inspect Elements", littleSolara: "page" },
  viewSource: { title: "View Source", littleSolara: "page" },
  back: { title: "Go Back", littleSolara: "page" },
  forward: { title: "Go Forward", littleSolara: "page" },
  nextTab: { title: "Next Tab" },
  previousTab: { title: "Previous Tab" },
  selectTab: {
    variants: Object.fromEntries([1, 2, 3, 4, 5, 6, 7, 8].map((n) => [String(n), { title: `Select Tab ${n}` }])),
  },
  selectLastTab: { title: "Select Last Tab" },
  togglePin: {
    title: "Move to Top Apps",
    symbol: "pin",
    variants: { tile: { title: "Move Pinned Tab to Top Apps" } },
  },
  togglePinnedRow: { title: "Move to Pinned" },
  duplicateTab: { title: "Duplicate", barTitle: "Duplicate Tab", symbol: "plus.square.on.square" },
  moveTabToProfile: {},
  moveTabToWindow: {},
  bookmarkPage: { title: "Add to Bookmarks…", symbol: "bookmark", littleSolara: "page" },
  addBookmarkToFolder: { littleSolara: "page" },
  openBookmark: { littleSolara: "page" },
  addFolderToSidebar: {},
  restoreArcFolders: {},
  toggleMute: { title: "Mute Site", symbol: "speaker.slash", littleSolara: "page" },
  togglePageEngine: { title: "Open Page in WebKit" },
  downloads: { title: "Downloads", symbol: "arrow.down.circle", littleSolara: "page" },
  mergeAllWindows: { title: "Merge All Windows", symbol: "rectangle.stack" },
  switchProfile: {},
  nextProfile: { title: "Next Profile" },
  previousProfile: { title: "Previous Profile" },
  newProfile: { title: "New Profile…", symbol: "person.crop.circle.badge.plus" },
  openSettings: { title: "Settings…", symbol: "gearshape" },
  importBrowserData: { title: "Import from Another Browser…", barTitle: "Import Browser Data", symbol: "square.and.arrow.down" },
  showHistory: { title: "Show History…", barTitle: "History", symbol: "clock" },
  clearBrowsingData: { title: "Clear Browsing Data…", symbol: "trash" },
  manageBookmarks: { title: "Manage Bookmarks", barTitle: "Bookmarks", symbol: "book" },
  bookmarkAllTabs: { title: "Bookmark All Tabs…" },
  setBookmarksBar: { variants: { always: { title: "Always" }, newTab: { title: "On New Tab Only" }, never: { title: "Never" } } },
  toggleBookmarksBar: { title: "Toggle Bookmarks Bar", symbol: "menubar.rectangle" },
  newTabInGroup: { title: "New Tab in Group" },
  newGroupWithTabs: { title: "New Group with Tab", symbol: "folder.badge.plus" },
  cleanUpTabs: { title: "Clean Up Tabs", symbol: "sparkles" },
  tidyPins: { title: "Tidy Pins", symbol: "sparkles" },
  searchTabs: { title: "Search Tabs…", symbol: "magnifyingglass" },
  renameTab: { title: "Rename…", barTitle: "Rename Tab", symbol: "pencil" },
  changeTabIcon: { title: "Change Icon…" },
  returnToPinnedUrl: { title: "Back to Pinned URL" },
  tabSwitcher: {
    variants: {
      forward: { title: "Tab Switcher (forward)" },
      backward: { title: "Tab Switcher (backward)" },
    },
  },
  share: { title: "Share…", barTitle: "Share", symbol: "square.and.arrow.up", littleSolara: "page" },
  reportBug: { title: "Report a Bug…", barTitle: "Report a Bug", symbol: "ladybug" },
  sendFeedback: { title: "Send Feedback…" },
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
  openFile: { title: "Open File…" },
  savePage: { title: "Save Page As…", littleSolara: "page" },
  emailPageLocation: { title: "Email Page Location", littleSolara: "page" },
  printWithSystemDialog: { title: "Print Using System Dialog…", littleSolara: "page" },
  stop: { title: "Stop", littleSolara: "page" },
  caretBrowsing: { title: "Caret Browsing", littleSolara: "page" },
  moveTabDown: { title: "Move Tab Down" },
  moveTabUp: { title: "Move Tab Up" },
  closeTabGroup: { title: "Close Group" },
  openProfileMenu: { title: "Show Profiles Menu" },
};

const ALL_COMMANDS = Object.keys(COMMANDS) as BrowserCommand[];
const commandsWhere = (test: (spec: CommandSpec) => boolean) => ALL_COMMANDS.filter((command) => test(COMMANDS[command]));

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

import { requireNativeViewManager, type EventSubscription } from "expo-modules-core";
import { processColor, StyleSheet, View, type ColorValue, type ViewProps } from "react-native";
import { nativeModule, optionalNativeModule } from "./nativeModules";
import type { ShortcutPrecedence } from "./system";

export * from "./system";
export * from "./app";
export * from "./live";
export * from "./cli";
export type { ShellNativeModules, ShellOptionalNativeModules } from "./nativeModules";

export type BrowserCommand =
  | "newTab"
  | "newWindow"
  | "newIncognitoWindow"
  | "newLittleSolara"
  | "toggleOpenLinksInLittleSolara"
  | "reopenClosedTab"
  | "reopenClosedWindow"
  | "restoreClosed"
  | "focusCommandBar"
  | "closeTab"
  | "closeAllTabs"
  | "print"
  | "copyUrl"
  | "copyUrlAsMarkdown"
  | "findInPage"
  | "findNext"
  | "findPrevious"
  | "setAppearance"
  | "reload"
  | "forceReload"
  | "toggleTabLayout"
  | "toggleSidebar"
  | "openSplitPane"
  | "useSelectionForFind"
  | "findAndReplace"
  | "jumpToSelection"
  | "focusNextPane"
  | "focusPreviousPane"
  | "toggleFullUrl"
  | "toggleDeveloperMode"
  | "toggleJavaScriptFromAppleEvents"
  | "toggleAddressBar"
  | "toggleSidebarIconsOnly"
  | "cast"
  | "zoomReset"
  | "zoomIn"
  | "zoomOut"
  | "devTools"
  | "toggleDevTools"
  | "javaScriptConsole"
  | "inspectElements"
  | "viewSource"
  | "back"
  | "forward"
  | "nextTab"
  | "previousTab"
  | "selectTab"
  | "selectLastTab"
  | "togglePin"
  | "togglePinnedRow"
  | "duplicateTab"
  | "moveTabToProfile"
  | "moveTabToWindow"
  | "bookmarkPage"
  | "addBookmarkToFolder"
  | "openBookmark"
  | "addFolderToSidebar"
  | "restoreArcFolders"
  | "toggleMute"
  | "togglePageEngine"
  | "downloads"
  | "mergeAllWindows"
  | "switchProfile"
  | "nextProfile"
  | "previousProfile"
  | "newProfile"
  | "openSettings"
  | "importBrowserData"
  | "showHistory"
  | "clearBrowsingData"
  | "manageBookmarks"
  | "bookmarkAllTabs"
  | "setBookmarksBar"
  | "toggleBookmarksBar"
  | "newTabInGroup"
  | "newGroupWithTabs"
  | "cleanUpTabs"
  | "tidyPins"
  | "searchTabs"
  | "renameTab"
  | "changeTabIcon"
  | "returnToPinnedUrl"
  | "tabSwitcher"
  | "share"
  | "sendFeedback"
  | "keyboardShortcuts"
  | "copyDiagnostics"
  | "recordPerformanceIssue"
  | "toolTour"
  | "videoTour"
  | "releaseNotes"
  | "showOnboarding"
  | "taskManager"
  | "openExtension"
  | "addExtension"
  | "manageExtensions"
  | "pinExtensions"
  | "autofill"
  | "openFile"
  | "savePage"
  | "emailPageLocation"
  | "printWithSystemDialog"
  | "stop"
  | "caretBrowsing"
  | "moveTabDown"
  | "moveTabUp"
  | "closeTabGroup"
  | "openProfileMenu";

export type CommandEvent = {
  command: BrowserCommand;
  arg: string | null;
  windowId: string | null;
  focusGeneration?: number | null;
};

export type WindowEvent =
  | { type: "focus"; id: string }
  | { type: "close"; id: string }
  | { type: "frame"; id: string; frame: [number, number, number, number] }
  | { type: "fullScreen"; id: string; on: boolean }
  | { type: "keptOnClose"; id: string; on: boolean }
  | { type: "leftEdge"; id: string; over: boolean; point: [number, number] }
  | { type: "closeRequest"; id: string };

export type AppEvent =
  | { type: "reopen" }
  | { type: "willQuit" }
  | { type: "quitCancelled" }
  | { type: "appearance"; dark: boolean }
  | { type: "quitWarningSuppressed" }
  | { type: "resignActive" }
  | { type: "screenLocked" }
  | { type: "switcherReleased" }
  | { type: "switcherKey"; key: "escape" | "next" | "previous" }
  | { type: "switcherMouseUp" }
  | { type: "dragEscape" };

type ShellEvents = {
  onCommand: (e: CommandEvent) => void;
  onOpenURLs: (e: { urls: string[]; pointer?: [number, number]; profile?: string | null }) => void;
  onWindowEvent: (e: WindowEvent) => void;
  onAppEvent: (e: AppEvent) => void;
};

export type MenuItem =
  | { separator: true }
  | {
      id: string;
      title: string;
      symbol?: string;
      swatch?: string;
      swatchDark?: string;
      key?: string;
      modifiers?: ("command" | "shift" | "option" | "control")[];
      enabled?: boolean;
      checked?: boolean;
      alternate?: boolean;
      children?: MenuItem[];
      share?: boolean;
    };

export type OpenWindowOptions = {
  frame?: [number, number, number, number] | null;
  incognito?: boolean;
  title?: string;
  focus?: boolean;
  kind?: "browser" | "small" | "settings" | "import";
  profile?: string;
  size?: [number, number];
  behind?: string;
  chromeWindow?: string;
  pointer?: [number, number];
  animated?: boolean;
};

export type MenuEntry = { id: string; title: string; current?: boolean };
export type MenuBookmark = { id: string; title: string; url?: string; children?: MenuBookmark[] };

export type MenuState = {
  checked: string[];
  disabled: string[];
  titles: Record<string, string>;
  profiles: MenuEntry[];
  windows: MenuEntry[];
  bookmarkNative?: { profileId: string; revision: number };
  bookmarkFolders: MenuEntry[];
  recentBookmarks: MenuBookmark[];
  bookmarksBar: MenuBookmark[];
  otherBookmarks: MenuBookmark[];
  recentlyClosed: MenuEntry[];
  recentlyClosedGroups?: MenuEntry[];
  warnBeforeQuitting: boolean;
  warnBeforeClosingWindow?: boolean;
  undoReopensClosedTab?: boolean;
  downloadsInProgress?: number;
  extensions?: { id: string; title: string; icon?: string | null; enabled: boolean }[];
  shortcuts?: Record<string, string[]>;
  shortcutPrecedence?: Record<string, ShortcutPrecedence>;
};

export type ConfirmOptions = {
  title: string;
  message?: string;
  confirmTitle?: string;
  cancelTitle?: string;
  destructive?: boolean;
  suppression?: string;
  windowId?: string;
};

export type PromptOptions = {
  title: string;
  message?: string;
  value?: string;
  placeholder?: string;
  confirmTitle?: string;
  windowId?: string;
};

export type ShellNative = {
  addListener<K extends keyof ShellEvents>(name: K, listener: ShellEvents[K]): EventSubscription;
  showMenu(items: MenuItem[]): Promise<string | null>;
  copyText(text: string): void;
  setSwitcherCapture(active: boolean): Promise<void>;
  setDragEscapeCapture?(active: boolean): Promise<void>;
  cancelFocusMove(generation: number, restoringSource: boolean): Promise<void>;
  claimFocus(generation: number, tag: number): Promise<void>;
  saveKeyResponder?(windowId: string): Promise<number>;
  restoreKeyResponder?(token: number): Promise<boolean>;
  discardKeyResponder?(token: number): Promise<void>;
  switcherPointerMoved?(): boolean;
  startDictation(): void;
  pickFiles(): Promise<string[]>;
  pickFolder?(current: string | null, prompt: string | null): Promise<string | null>;
  readDocument(name: string): string | null;
  readDocumentResult?(name: string): { contents?: string; failure?: string; path?: string };
  writeDocument(name: string, contents: string): void;
  saveDocument(name: string, contents: string): Promise<void>;
  removeDocument(name: string): void;
  listDocuments?(prefix: string): string[];
  fetchBangList?(etag: string | null): Promise<BangListReply>;
  openWindow(id: string, options: OpenWindowOptions): Promise<void>;
  retainLastWindow(id: string, committingClose?: boolean): Promise<boolean>;
  closeWindow(id: string): Promise<void>;
  animateWindowClose?(id: string, after: string | null): Promise<void>;
  focusWindow(id: string, cancellingClose?: boolean): Promise<void>;
  restoreFullScreen?(ids: string[], focus: string | null): Promise<void>;
  setTrafficLightsCenter(id: string, center: [number, number] | null): Promise<void>;
  watchLeftEdge?(id: string, on: boolean, hold: number): Promise<void>;
  dragPreviewBegin?(windowId: string, chip: Rect4, grab: [number, number]): Promise<void>;
  dragPreviewPage?(base64: string, frame: Rect4): Promise<void>;
  dragPreviewUpdate?(shape: DragPreviewShape, point: [number, number]): Promise<void>;
  dragPreviewCancel?(): Promise<void>;
  raiseView?(tag: number, levels: number, raised: boolean): Promise<void>;
  dragPreviewPlaceholder?(title: string, favicon: string | null): Promise<void>;
  windowFrame?(id: string): Promise<Rect4 | null>;
  dragPreviewEnd?(windowId: string | null, frame: Rect4 | null): Promise<void>;
  setWindowTitle(id: string, title: string): Promise<void>;
  windowIds(): Promise<string[]>;
  setAppearance(mode: "auto" | "light" | "dark"): Promise<void>;
  isDarkAppearance(): Promise<boolean>;
  bookmarkNativeSourceVersion?(): number;
  setMenuState(state: Omit<MenuState, MenuBookmarkKey>): Promise<void>;
  setMenuBookmarks(bookmarks: Pick<MenuState, MenuBookmarkKey>): Promise<void>;
  replyToTerminate(ok: boolean): Promise<void>;
  confirm(options: ConfirmOptions): Promise<{ confirmed: boolean; suppressed: boolean }>;
  prompt(options: PromptOptions): Promise<string | null>;
};

const Shell = nativeModule("SolaraShell");

export const readDocument = (name: string) => Shell.readDocument(name);
export type DocumentRead = { contents: string } | { missing: true } | { failure: string; path: string };
export function readDocumentResult(name: string): DocumentRead {
  if (!Shell.readDocumentResult) {
    const contents = Shell.readDocument(name);
    return contents === null ? { missing: true } : { contents };
  }
  const read = Shell.readDocumentResult(name);
  if (typeof read.contents === "string") return { contents: read.contents };
  if (typeof read.failure === "string") return { failure: read.failure, path: read.path ?? name };
  return { missing: true };
}
export const writeDocument = (name: string, contents: string) => Shell.writeDocument(name, contents);
export const saveDocument = (name: string, contents: string) => Shell.saveDocument(name, contents);
export const removeDocument = (name: string) => Shell.removeDocument(name);
export const listDocuments = (prefix: string): string[] | null => Shell.listDocuments?.(prefix) ?? null;

export type BangListReply = { status: number; etag: string | null; contentType: string | null; body: string | null; bytes: number };
export const fetchBangList = (etag: string | null): Promise<BangListReply> | null => Shell.fetchBangList?.(etag) ?? null;

export const startDictation = () => Shell.startDictation();
export const setSwitcherCapture = (active: boolean) => void Shell.setSwitcherCapture(active);
export const setDragEscapeCapture = (active: boolean) => void Shell.setDragEscapeCapture?.(active);
export const cancelFocusMove = (generation: number, restoringSource: boolean) =>
  void Shell.cancelFocusMove(generation, restoringSource);
export const claimFocus = (generation: number, tag: number) => void Shell.claimFocus(generation, tag);
export const saveKeyResponder = (windowId: string): Promise<number> => Shell.saveKeyResponder?.(windowId) ?? Promise.resolve(0);
export const restoreKeyResponder = (token: number): Promise<boolean> => (token ? (Shell.restoreKeyResponder?.(token) ?? Promise.resolve(false)) : Promise.resolve(false));
export const discardKeyResponder = (token: number): void => {
  if (token) void Shell.discardKeyResponder?.(token);
};
export const restartSwitcherPointer = () => Shell.setSwitcherCapture(true);
export const switcherPointerMoved = () => Shell.switcherPointerMoved?.() ?? true;
export const pickFiles = () => Shell.pickFiles();
export const pickFolder = (current: string | null, prompt: string | null = null) => Shell.pickFolder?.(current, prompt) ?? Promise.resolve(null);

export function copyText(text: string) {
  Shell.copyText(text);
}

let menusShown = 0;
const menuWatchers = new Set<() => void>();
const menusChanged = (by: number) => {
  menusShown += by;
  for (const watcher of menuWatchers) watcher();
};
export const menuShown = () => menusShown > 0;
export function watchMenus(watcher: () => void): () => void {
  menuWatchers.add(watcher);
  return () => void menuWatchers.delete(watcher);
}

export function showMenu(items: MenuItem[]): Promise<string | null> {
  menusChanged(1);
  return Promise.resolve(Shell.showMenu(items)).finally(() => menusChanged(-1));
}

export const openWindow = (id: string, options: OpenWindowOptions = {}) => Shell.openWindow(id, options);

export type WindowProfileProps = ViewProps & {
  profile: string;
  selection?: string;
  neighbours: string[];
};
export const WindowProfile = requireNativeViewManager<WindowProfileProps>("SolaraWindowProfile");

export const retainLastWindow = (id: string, committingClose = false) => Shell.retainLastWindow(id, committingClose);
export const closeWindow = (id: string) => Shell.closeWindow(id);
export const animateWindowClose = (id: string, after: string | null = null) => Shell.animateWindowClose?.(id, after) ?? Promise.resolve();
export const restoreFullScreen = (ids: string[], focus: string | null) => Shell.restoreFullScreen?.(ids, focus) ?? Promise.resolve();
export const focusWindow = (id: string, cancellingClose = false) => Shell.focusWindow(id, cancellingClose);
export const setWindowTitle = (id: string, title: string) => Shell.setWindowTitle(id, title);
export const setTrafficLightsCenter = (id: string, center: [number, number] | null) =>
  Shell.setTrafficLightsCenter(id, center);
export const watchLeftEdge = (id: string, on: boolean, hold = 0) => void Shell.watchLeftEdge?.(id, on, hold);
type Rect4 = [number, number, number, number];
export type DragPreviewShape = "hidden" | "pill" | "card";
export const dragPreview = {
  begin: (windowId: string, chip: Rect4, grab: [number, number]) => void Shell.dragPreviewBegin?.(windowId, chip, grab),
  page: (base64: string, frame: Rect4) => void Shell.dragPreviewPage?.(base64, frame),
  update: (shape: DragPreviewShape, point: [number, number]) => void Shell.dragPreviewUpdate?.(shape, point),
  end: (windowId: string | null = null, frame: Rect4 | null = null) => void Shell.dragPreviewEnd?.(windowId, frame),
  cancel: () => void Shell.dragPreviewCancel?.(),
  placeholder: (title: string, favicon: string | null) => void Shell.dragPreviewPlaceholder?.(title, favicon),
};
export const raiseView = (tag: number | null, levels: number, raised: boolean) => {
  if (tag != null) void Shell.raiseView?.(tag, levels, raised);
};
export const windowFrame = (id: string): Promise<Rect4 | null> => Shell.windowFrame?.(id) ?? Promise.resolve(null);
export const windowIds = () => Shell.windowIds();

export const setAppearance = (mode: "auto" | "light" | "dark") => Shell.setAppearance(mode);
export const isDarkAppearance = () => Shell.isDarkAppearance();

export const nativeBookmarkMenuSourceAvailable = () => Shell.bookmarkNativeSourceVersion?.() === 1;

type MenuBookmarkKey = "bookmarkNative" | "bookmarkFolders" | "recentBookmarks" | "bookmarksBar" | "otherBookmarks";
export function setMenuStateParts(state: MenuState, bookmarksChanged: boolean) {
  const { bookmarkNative, bookmarkFolders, recentBookmarks, bookmarksBar, otherBookmarks, ...rest } = state;
  if (bookmarksChanged) void Shell.setMenuBookmarks(bookmarkNative ? { bookmarkNative, bookmarkFolders: [], recentBookmarks: [], bookmarksBar: [], otherBookmarks: [] } : { bookmarkFolders, recentBookmarks, bookmarksBar, otherBookmarks });
  return Shell.setMenuState(rest);
}
export const replyToTerminate = (ok: boolean) => Shell.replyToTerminate(ok);

export const confirm = (options: ConfirmOptions) => Shell.confirm(options);
export const prompt = (options: PromptOptions) => Shell.prompt(options);

export const onCommand = (listener: (e: CommandEvent) => void) => Shell.addListener("onCommand", listener);
export const onWindowEvent = (listener: (e: WindowEvent) => void) => Shell.addListener("onWindowEvent", listener);
export const onAppEvent = (listener: (e: AppEvent) => void) => Shell.addListener("onAppEvent", listener);
export const onOpenURLs = (listener: (urls: string[], pointer?: [number, number], profile?: string) => void) =>
  Shell.addListener("onOpenURLs", ({ urls, pointer, profile }) => listener(urls, pointer, profile ?? undefined));

export const WindowDragRegion = requireNativeViewManager<
  ViewProps & { titleBarDoubleClick?: boolean; onRegionDoubleClick?: () => void; clickable?: boolean; onRegionClick?: () => void }
>("SolaraShell");

export const OutsidePressArea = requireNativeViewManager<ViewProps & { onOutsidePress?: (event: { nativeEvent: { timestamp?: number } }) => void }>("SolaraOutsidePressArea");

export type SymbolProps = ViewProps & {
  name: string;
  size?: number;
  weight?: "light" | "regular" | "medium" | "semibold" | "bold";
  color?: string;
};

export const Symbol = requireNativeViewManager<SymbolProps>("SolaraSymbol");

export type FadeLabelProps = ViewProps & {
  text: string;
  fontSize?: number;
  weight?: "light" | "regular" | "medium" | "semibold" | "bold";
  color?: string;
  fadeWidth?: number;
};

export const FadeLabel = requireNativeViewManager<FadeLabelProps>("SolaraFadeLabel");

export const ActivitySpinner = requireNativeViewManager<ViewProps>("SolaraActivitySpinner");

export type HairlineProps = ViewProps & { color: ColorValue; edge?: "top" | "bottom"; thickness?: number };

export type HairlineNative = Record<string, never>;

const NativeHairline = optionalNativeModule("SolaraHairline")
  ? requireNativeViewManager<Omit<HairlineProps, "color"> & { color: ReturnType<typeof processColor> }>("SolaraHairline")
  : null;

export function Hairline({ color, edge = "bottom", thickness, style, ...props }: HairlineProps) {
  if (NativeHairline) return <NativeHairline pointerEvents="none" {...props} style={style} edge={edge} thickness={thickness} color={processColor(color)} />;
  const width = thickness ?? StyleSheet.hairlineWidth;
  const border = edge === "top" ? { borderTopWidth: width, borderTopColor: color } : { borderBottomWidth: width, borderBottomColor: color };
  return <View pointerEvents="none" {...props} style={[style, border]} />;
}

export type ContextMenuAreaProps = ViewProps & {
  onContextMenu?: () => void;
  captureDescendants?: boolean;
};

const NativeContextMenuArea = requireNativeViewManager<Omit<ContextMenuAreaProps, "onContextMenu"> & { onContextMenu?: () => void }>(
  "SolaraContextMenuArea",
);

export function ContextMenuArea(props: ContextMenuAreaProps) {
  return <NativeContextMenuArea {...props} />;
}

export type SurfaceProps = ViewProps & {
  fill?: string;
  cornerRadius?: number;
  borderColor?: string;
  borderWidth?: number;
  borderColors?: string[];
  shadowColor?: string;
  shadowOpacity?: number;
  shadowRadius?: number;
  shadowOffset?: [number, number];
};

type NativeSurfaceProps = Omit<SurfaceProps, "shadowColor" | "shadowOpacity" | "shadowRadius" | "shadowOffset"> & {
  surfaceShadowColor?: string;
  surfaceShadowOpacity?: number;
  surfaceShadowRadius?: number;
  surfaceShadowOffset?: [number, number];
};

const NativeSurface = requireNativeViewManager<NativeSurfaceProps>("SolaraSurface");

export function Surface({ shadowColor, shadowOpacity, shadowRadius, shadowOffset, ...props }: SurfaceProps) {
  return (
    <NativeSurface
      {...props}
      surfaceShadowColor={shadowColor}
      surfaceShadowOpacity={shadowOpacity}
      surfaceShadowRadius={shadowRadius}
      surfaceShadowOffset={shadowOffset}
    />
  );
}

export type VisualEffectProps = ViewProps & {
  material?: string;
  blendingMode?: "withinWindow" | "behindWindow";
  cornerRadius?: number;
};

export const VisualEffect = requireNativeViewManager<VisualEffectProps>("SolaraVisualEffect");

export type GlassEffectProps = ViewProps & {
  cornerRadius?: number;
  tint?: string;
  glassStyle?: "regular" | "clear";
  dark?: boolean;
};

export type GlassEffectNative = { isLiquidGlass(): boolean };

const GlassEffectModule = nativeModule("SolaraGlassEffect");

export const isLiquidGlass = (): boolean => GlassEffectModule.isLiquidGlass();

export const GlassEffect = requireNativeViewManager<GlassEffectProps>("SolaraGlassEffect");

export type PopoverBubbleProps = ViewProps & {
  material?: "popover" | "menu" | "hudWindow" | "sheet" | "toolTip";
  dark?: boolean;
  cornerRadius?: number;
  arrowEdge?: "top" | "bottom" | "none";
  arrowX?: number;
  arrowWidth?: number;
  arrowHeight?: number;
  tint?: string;
  edgeColor?: string;
  edgeWidth?: number;
  shadowOpacity?: number;
  shadowRadius?: number;
  shadowOffsetY?: number;
};

type NativePopoverBubbleProps = Omit<PopoverBubbleProps, "shadowOpacity" | "shadowRadius" | "shadowOffsetY"> & {
  bubbleShadowOpacity?: number;
  bubbleShadowRadius?: number;
  bubbleShadowOffsetY?: number;
};

export type PopoverBubbleNative = { isAvailable(): boolean };

export const popoverBubbleAvailable = !!optionalNativeModule("SolaraPopoverBubble")?.isAvailable();

const NativePopoverBubble = popoverBubbleAvailable ? requireNativeViewManager<NativePopoverBubbleProps>("SolaraPopoverBubble") : null;

export function PopoverBubble({ shadowOpacity, shadowRadius, shadowOffsetY, ...props }: PopoverBubbleProps) {
  if (!NativePopoverBubble) return null;
  return <NativePopoverBubble {...props} bubbleShadowOpacity={shadowOpacity} bubbleShadowRadius={shadowRadius} bubbleShadowOffsetY={shadowOffsetY} />;
}

export type IconTheme = { kind: "blur" } | { kind: "template"; fill: string; stroke?: string };

export type DockSelectionNative = {
  iconTheme(uri: string | null, emoji: string | null): Promise<IconTheme | null>;
};

const DockSelectionModule = nativeModule("SolaraDockSelection");

export const iconTheme = (source: { uri: string } | { emoji: string }): Promise<IconTheme | null> =>
  DockSelectionModule.iconTheme("uri" in source ? source.uri : null, "emoji" in source ? source.emoji : null);

export type DockSelectionProps = ViewProps & {
  image?: string;
  emoji?: string;
  theme?: IconTheme["kind"];
  fill?: string;
  stroke?: string;
  cornerRadius?: number;
  strokeWidth?: number;
  iconSize?: number;
  dark: boolean;
  glass?: boolean;
};

export const DockSelection = requireNativeViewManager<DockSelectionProps>("SolaraDockSelection");

export type InlineCompletionNative = {
  complete(tag: number, typed: string, completion: string): Promise<InlineWrite>;
};

const InlineCompletionModule = nativeModule("SolaraInlineCompletion");

export type InlineWrite = 0 | 1 | 2;

export const completeInline = (tag: number, typed: string, completion: string) =>
  InlineCompletionModule.complete(tag, typed, completion);

export type TranslationModule = {
  readonly available: boolean;
  userLanguages(): string[];
  languageName(identifier: string): string;
  detect(text: string): Promise<string | null>;
  status(source: string, target: string): Promise<"installed" | "supported" | "unsupported">;
  supportedLanguages(): Promise<string[]>;
  prepare(source: string, target: string): Promise<void>;
  translate(source: string, target: string, texts: string[]): Promise<(string | null)[]>;
  translateBlocks(source: string, target: string, blocks: string[][]): Promise<(string[] | null)[]>;
};
const TranslationNative = nativeModule("SolaraTranslate");

export const translation: Omit<TranslationModule, "available"> | null = TranslationNative.available ? TranslationNative : null;

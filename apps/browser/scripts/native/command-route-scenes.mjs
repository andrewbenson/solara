const { useBrowser } = await import("../../src/store/browser.ts");
const { startClosingWindow, stopClosingWindow } = await import("../../src/store/closingWindows.ts");

const S = () => useBrowser.getState();

export const ROUTE_SLICES = ["windows", "windowOrder", "tabs", "peeks", "find", "windowUi", "ui"];

function main() {
  const w = S().createWindow({ url: "https://a.example/" });
  const a = S().windows[w].tabIds[0];
  const b = S().newTab(w, { url: "https://b.example/", background: true });
  return { w, a, b };
}

function withSmall() {
  const ids = main();
  return { ...ids, small: S().createWindow({ url: "https://s.example/", small: true }) };
}

function withPeek({ find = false, panel = false } = {}) {
  const ids = main();
  const peek = S().openPeek(ids.a, "https://peek.example/");
  if (find) S().setFind(peek, { open: true });
  if (panel) S().openPanel(ids.w, "");
  return { ...ids, peek };
}

function smallWithPeek() {
  const ids = withSmall();
  const smallPeek = S().openPeek(ids.a, "https://small-peek.example/");
  useBrowser.setState((s) => {
    const { [ids.w]: moved, ...rest } = s.peeks;
    return { peeks: { ...rest, [ids.small]: moved }, tabs: { ...s.tabs, [smallPeek]: { ...s.tabs[smallPeek], windowId: ids.small } } };
  });
  return { ...ids, smallPeek };
}

function withClosingMain() {
  const ids = withSmall();
  const other = S().createWindow({ url: "https://o.example/" });
  S().setFocusedWindow(ids.w);
  return { ...ids, other };
}

function incognitoOnly() {
  const incog = S().createWindow({ url: "https://i.example/", incognito: true });
  const small = S().createWindow({ url: "https://s.example/", small: true });
  return { incog, small };
}

function patch(change) {
  useBrowser.setState((s) => change(s));
}

function emptyPeekTab() {
  const ids = withPeek();
  patch((s) => ({ peeks: { ...s.peeks, [ids.w]: { ...s.peeks[ids.w], tabId: "" } } }));
  return ids;
}

function emptyProfile() {
  const ids = withSmall();
  const w2 = S().createWindow({ url: "https://two.example/" });
  patch((s) => ({
    windows: {
      ...s.windows,
      [ids.small]: { ...s.windows[ids.small], profileId: "" },
      [w2]: { ...s.windows[w2], profileId: "" },
    },
    ui: { ...s.ui, focusOrder: [ids.small, ids.w, w2] },
  }));
  return { ...ids, w2 };
}

function profilePreference() {
  const ids = withSmall();
  const work = S().createWindow({ url: "https://work.example/" });
  patch((s) => ({
    windows: {
      ...s.windows,
      [ids.small]: { ...s.windows[ids.small], profileId: "work" },
      [work]: { ...s.windows[work], profileId: "work", activeTabIds: { work: s.windows[work].tabIds[0] } },
    },
    ui: { ...s.ui, focusOrder: [ids.small, ids.w, work] },
  }));
  return { ...ids, work };
}

function noFocusOrder() {
  const ids = main();
  patch((s) => ({ ui: { ...s.ui, focusOrder: [] } }));
  return ids;
}

function smallAndStaleFocusOrder() {
  const ids = withSmall();
  patch((s) => ({ ui: { ...s.ui, focusOrder: [ids.small, "stale-window"] } }));
  return ids;
}

function emptyActiveTab() {
  const ids = main();
  patch((s) => {
    const w = s.windows[ids.w];
    return {
      tabs: { ...s.tabs, "": { ...s.tabs[ids.a], id: "" } },
      windows: { ...s.windows, [ids.w]: { ...w, activeTabIds: { ...w.activeTabIds, [w.profileId]: "" } } },
    };
  });
  return ids;
}

const none = () => ({});
const at = (role) => (ids) => (role === null ? null : (ids[role] ?? role));
const route = (kind, windowId = null, focusWindow = null, tabId = null) => ({ kind, windowId, focusWindow, tabId });

export const SCENES = [
  ["settings closeTab closes the settings window", main, "closeTab", "settings", null, [], route("utilityClose", "settings")],
  ["settings findInPage focuses Settings search", main, "findInPage", "settings", null, [], route("settingsSearch", "settings")],
  ["import closeTab closes the import window", main, "closeTab", "import", null, [], route("utilityClose", "import")],
  ["import window drops its id for a page command", main, "reload", "import", null, [], route("main", "w", null, "a")],
  ["import findInPage is an ordinary page command", main, "findInPage", "import", null, [], route("main", "w", null, "a")],
  ["a window-level command from Settings has no window", main, "newWindow", "settings", null, [], route("window")],
  ["small closeTab stays in Little Solara", withSmall, "closeTab", "small", null, [], route("littleSolara", "small")],
  ["small focusCommandBar stays in Little Solara", withSmall, "focusCommandBar", "small", null, [], route("littleSolara", "small")],
  ["small reload stays on the small window's page", withSmall, "reload", "small", null, [], route("main", "small", null, "small.active")],
  ["small newTab goes to the profile's main window and focuses it", withSmall, "newTab", "small", null, [], route("main", "w", "w", "a")],
  ["small nextTab goes to the main window", withSmall, "nextTab", "small", null, [], route("main", "w", "w", "a")],
  ["small newWindow is window-level, not redirected", withSmall, "newWindow", "small", null, [], route("window", "small")],
  ["small toggleBookmarksBar is window-level", withSmall, "toggleBookmarksBar", "small", null, [], route("window", "small")],
  ["small addFolderToSidebar keeps the invoking window", withSmall, "addFolderToSidebar", "small", "folder", [], route("invoker", "small", "w")],
  ["main addFolderToSidebar", main, "addFolderToSidebar", "w", "folder", [], route("invoker", "w")],
  ["small newTab skips a closing main window", withClosingMain, "newTab", "small", null, ["w"], route("main", "other", "other", "other.active")],
  ["Peek openFile promotes the Peek", () => withPeek(), "openFile", "w", null, [], route("peekPromote", "w", null, "peek")],
  ["Peek closeTab with find open closes find", () => withPeek({ find: true }), "closeTab", "w", null, [], route("peekCloseFind", "w", null, "peek")],
  ["Peek closeTab dismisses the Peek", () => withPeek(), "closeTab", "w", null, [], route("peekDismiss", "w", null, "peek")],
  ["Peek closeTab with the panel open falls through", () => withPeek({ panel: true }), "closeTab", "w", null, [], route("main", "w", null, "a")],
  ["a Little Solara page command targets the Peek tab", () => withPeek(), "reload", "w", null, [], route("main", "w", null, "peek")],
  ["a window command ignores the Peek tab", () => withPeek(), "nextTab", "w", null, [], route("main", "w", null, "a")],
  ["Peek reached with no window id", () => withPeek(), "closeTab", null, null, [], route("peekDismiss", "w", null, "peek")],
  ["Peek reached with an unknown window id", () => withPeek(), "openFile", "gone", null, [], route("peekPromote", "w", null, "peek")],
  ["Peek reached from the import window", () => withPeek(), "openFile", "import", null, [], route("peekPromote", "w", null, "peek")],
  ["a Peek moved into a small window is dropped, and closeTab stays Little Solara's", smallWithPeek, "closeTab", "small", null, [], route("littleSolara", "small")],
  ["a Peek moved into a small window is dropped, and a page command uses its own tab", smallWithPeek, "reload", "small", null, [], route("main", "small", null, "small.active")],
  ["a redirect with only incognito windows finds no main window", incognitoOnly, "newTab", "small", null, [], route("main", "incog", null, "incog.active")],
  ["no window newTab", none, "newTab", null, null, [], route("noWindow")],
  ["no window reopenClosedTab", none, "reopenClosedTab", null, null, [], route("noWindow")],
  ["no window restoreClosed with an argument", none, "restoreClosed", null, "entry", [], route("noWindow")],
  ["a window-level command with no window", none, "openSettings", null, null, [], route("window")],
  ["unknown window falls back to the focused main window", main, "reload", "gone", null, [], route("main", "w", null, "a")],
  ["no requested window uses the focused main window", main, "duplicateTab", null, null, [], route("main", "w", null, "a")],
  ["a Peek with an empty tab id is dropped by the store", emptyPeekTab, "reload", "w", null, [], route("main", "w", null, "a")],
  ["a redirect prefers a main window on the small window's profile", profilePreference, "newTab", "small", null, [], route("main", "work", "work", "work.active")],
  ["a folder command with no window", none, "addFolderToSidebar", null, "folder", [], route("invoker")],
  ["a folder command from a utility window uses the focused main window", main, "addFolderToSidebar", "settings", "folder", [], route("invoker", "w")],
  ["a folder command from a small window with only incognito windows", incognitoOnly, "addFolderToSidebar", "small", "folder", [], route("invoker", "small")],
  ["Peek openFile with the panel open still promotes", () => withPeek({ panel: true }), "openFile", "w", null, [], route("peekPromote", "w", null, "peek")],
  ["Peek closeTab with find and the panel open falls through", () => withPeek({ find: true, panel: true }), "closeTab", "w", null, [], route("main", "w", null, "a")],
  ["with no focus order the window order decides", noFocusOrder, "reload", null, null, [], route("main", "w", null, "a")],
  ["with only small and stale ids in the focus order the window order decides", smallAndStaleFocusOrder, "reload", null, null, [], route("main", "w", null, "a")],
  ["an empty profile id redirects to the first main window", emptyProfile, "newTab", "small", null, [], route("main", "w", "w", "a")],
  ["an empty active tab id is no tab", emptyActiveTab, "duplicateTab", "w", null, [], route("main", "w")],
].map(([name, build, command, windowRole, arg, closingRoles, expect]) => ({ name, build, command, windowRole, arg, closingRoles, expect }));

export function roleNames(ids) {
  const roles = {};
  for (const [role, id] of Object.entries(ids)) roles[role] = id;
  for (const [role, id] of Object.entries(ids)) {
    const w = S().windows[id];
    const active = w?.activeTabIds[w.profileId];
    if (active && !Object.values(roles).includes(active)) roles[`${role}.active`] = active;
  }
  return roles;
}

export function symbolic(route, roles) {
  const names = {};
  for (const [role, id] of Object.entries(roles)) if (!(id in names)) names[id] = role;
  const name = (id) => (id === null || id === "settings" || id === "import" || id === "gone" ? id : (names[id] ?? `unnamed:${id}`));
  return { kind: route.kind, windowId: name(route.windowId), focusWindow: name(route.focusWindow), tabId: name(route.tabId) };
}

export function plainState() {
  return JSON.parse(JSON.stringify(Object.fromEntries(ROUTE_SLICES.map((k) => [k, S()[k]]))));
}

export function play(scene, resolve) {
  S().hydrate({});
  const ids = scene.build();
  const roles = roleNames(ids);
  const windowId = at(scene.windowRole)(ids);
  const closing = scene.closingRoles.map((role) => ids[role]);
  for (const id of closing) startClosingWindow(id);
  try {
    const state = plainState();
    return { name: scene.name, command: scene.command, arg: scene.arg, windowId, closing, roles, state, route: resolve(scene, windowId) };
  } finally {
    for (const id of closing) stopClosingWindow(id);
  }
}

export function withClosing(ids, body) {
  for (const id of ids) startClosingWindow(id);
  try {
    return body();
  } finally {
    for (const id of ids) stopClosingWindow(id);
  }
}

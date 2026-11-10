import assert from "node:assert/strict";
import { mkdtempSync, rmSync } from "node:fs";
import { createServer } from "node:http";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { isDeepStrictEqual } from "node:util";
import { launch, reporter, session, sleep } from "../../../scripts/lib/instance.mjs";

const HELP = `Checks native panel, sidebar and New Tab command bars on isolated local fixtures.

  node apps/browser/scripts/omnibox-test.mjs <Debug Solara.app> [--keep-data]

Requires the pod driver-state hooks delivered with this test. Uses the harness uitest lock;
AC_UITEST_WAIT defaults to 0 (fail if busy). One hidden instance, a 100-second run budget
and a separate 10-second teardown deadline. Enter, Escape and arrows use the window's field editor;
local navigation/search only, remote suggestions disabled. Calculator and bang rows are
observed without executing their clipboard/network actions. State and rows are read from the native model;
the JS driver cache is diagnostic only. Selection keys wait for native selection before the next key;
this does not verify SwiftUI row rendering or accessibility. Logs stay on failure.`;
const args = process.argv.slice(2);
if (args.includes("--help") || args.includes("-h")) {
  console.log(HELP);
  process.exit(0);
}
const appArg = args.find((arg) => !arg.startsWith("--"));
if (!appArg || args.some((arg) => arg.startsWith("--") && arg !== "--keep-data")) {
  console.error(HELP);
  process.exit(2);
}
const appPath = resolve(appArg);
assert.ok(!appPath.startsWith("/Applications/") && !appPath.includes("/build-vista/"), "pass a scratch Debug build");
process.env.AC_UITEST_WAIT ??= "0";
const keep = args.includes("--keep-data");
if (keep) process.env.AC_KEEP_DATA = "1";
const scratch = mkdtempSync(join(tmpdir(), "ac-omnibox-"));
const rep = reporter(join(scratch, "omnibox-test.log"), { name: "omnibox-test" });
const requests = new Map();
const server = createServer((req, res) => {
  requests.set(req.url, (requests.get(req.url) ?? 0) + 1);
  const title = req.url === "/open" ? "Omni Open Fixture" : req.url === "/bookmark" ? "Omni Bookmark Fixture" : "Omni Local Fixture";
  res.writeHead(200, { "content-type": "text/html", "cache-control": "no-store" });
  res.end(`<!doctype html><title>${title}</title><link rel="icon" href="data:,"><body><button>Local fixture</button></body>`);
});
let instance = null;
let launching = null;
let cleanupPromise = null;
let budget = null;
let stopping = false;
let openLoads = null;
const cleanup = () => cleanupPromise ??= (async () => {
  const deadline = setTimeout(() => {
    rep.record("10-second teardown deadline", { error: new Error("cleanup did not settle") });
    process.exit(1);
  }, 10_000);
  try {
    const closed = new Promise((done) => server.listening ? server.close(done) : done());
    server.closeAllConnections();
    await closed;
    const owned = instance ?? await launching?.catch(() => null);
    if (owned) await owned.quit({ graceful: false });
  } finally {
    clearTimeout(budget);
    clearTimeout(deadline);
  }
})();
const stop = async (code) => {
  stopping = true;
  process.exitCode = code;
  try { await cleanup(); } catch (error) { rep.record("cleanup", { error }); }
  process.exit(code);
};
for (const [signal, code] of [["SIGINT", 130], ["SIGTERM", 143], ["SIGHUP", 129]]) {
  process.once(signal, () => void stop(code));
}
const run = (body, timeout = 4000) => {
  assert.ok(!stopping, "test is stopping");
  return instance.eval(body, { timeout });
};
const until = async (name, read, accept = Boolean, ms = 4000) => {
  const end = Date.now() + ms;
  let last;
  do {
    assert.ok(instance.stillOwned(), `${name}: instance exited`);
    if (end - Date.now() < 1000) break;
    last = await read(end);
    if (Date.now() < end && await accept(last, end) && Date.now() < end) return last;
    await sleep(40);
  } while (Date.now() < end);
  throw new Error(`${name}: timed out (${JSON.stringify(last)})`);
};
const nativeWindow = async (name, accept) => {
  const snapshot = await until(name, () => instance.snapshot({ windowId: "w1" }, { timeout: 1000 }),
    (state, end) => state.consistent && accept(state.windows.find((window) => window.id === "w1"), state, end));
  return snapshot;
};
const fillOf = (row) => {
  if (row?.kind === "search") return row.bang ? null : row.query;
  if (row?.kind !== "page") return null;
  const scheme = /^https?:\/\//i.exec(row.url);
  if (!scheme) return row.url;
  const rest = row.url.slice(scheme[0].length);
  return rest.indexOf("/") === rest.length - 1 ? rest.slice(0, -1) : rest;
};
const shownFor = (state) => (state.selected > 0 && fillOf(state.items[state.selected])) || state.typed + state.completion;
const plainURL = (url) => typeof url === "string" && /^https?:\/\/[^/@]*\//i.test(url);
const snapshotRowMatches = (row, item) => row?.kind === item.kind
  && row.tabId === (item.tabId ?? null)
  && row.title === (typeof item.title === "string" ? item.title.slice(0, 512) : null)
  && (!plainURL(item.url) || row.url === item.url);
const snapshotMatches = (omnibox, state) => !!omnibox
  && omnibox.source === (current.newTab ? "panel" : "anchor")
  && omnibox.variant === state.variant && omnibox.open === true && omnibox.focused === true
  && omnibox.selectedIndex === state.selected
  && (plainURL(state.typed) || !/^[A-Za-z][A-Za-z0-9+.-]*:/.test(state.typed) ? omnibox.typed === state.typed.slice(0, 512) : true)
  && Array.isArray(omnibox.rows) && omnibox.rows.length === Math.min(state.items.length, 64)
  && omnibox.rows.every((row, index) => snapshotRowMatches(row, state.items[index]));
let current = null;
const readPair = (end) => {
  if (end - Date.now() < 1000) return null;
  return run(`
    const cached = ac.omnibox.get(${JSON.stringify("w1:")} + ${JSON.stringify(current.variant)})?.state();
    return globalThis.__omniboxNative.driverState().then((json) => ({ cached, native: JSON.parse(json) }));
  `, 1000);
};
const observe = async (name, accept = () => true) => {
  const valid = ({ native } = {}) => {
    if (!native) return false;
    if (!native.windowId) return false;
    assert.equal(native.observationVersion, 2, "rebuild with the version 2 native observation hooks");
    if (!accept(native) || !Array.isArray(native.items) || !native.mounted || !native.fieldAttached || native.listAway !== false) return false;
    if (native.windowId !== "w1" || native.tabId !== "a" || native.profileId !== "default" || native.variant !== current.variant || native.opensTab !== current.newTab) return false;
    if (!native.focused || native.fieldValue !== native.value || !isDeepStrictEqual(native.fieldSelection, native.selection)) return false;
    return true;
  };
  let pair;
  const snapshot = await nativeWindow(`${name} probe snapshot rows`, async (window, snapshot, end) => {
    pair = await readPair(end);
    if (!pair || !valid(pair)) return false;
    const state = pair.native;
    return window?.profileId === "default" && window.selectedTabId === state.tabId
      && (current.newTab || isDeepStrictEqual(window.focusedURL?.selection, state.selection)
        && (!/^https?:\/\//.test(state.value) || window.focusedURL?.value === state.value))
      && snapshotMatches(window?.omnibox, state);
  });
  const state = pair.native;
  assert.equal(state.windowId, "w1");
  assert.equal(state.profileId, "default");
  assert.equal(state.variant, current.variant);
  assert.equal(state.opensTab, current.newTab);
  assert.equal(state.focused, true, "native field owns its window's editor");
  assert.equal(state.fieldValue, state.value, "AppKit field displays the model value");
  assert.deepEqual(state.fieldSelection, state.selection, "AppKit selection matches the native model");
  assert.ok(Array.isArray(state.items), "native model exposes the ordered suggestion list");
  rep.log(`${name} probe snapshot`, snapshot.windows.find((window) => window.id === "w1").omnibox);
  rep.log(name, state);
  const differences = ["windowId", "tabId", "profileId", "variant", "opensTab", "typed", "value", "completion", "selection", "scope", "selected", "items"]
    .filter((key) => !isDeepStrictEqual(pair.cached?.[key], state[key]));
  if (differences.length) rep.log(`${name} JS cache diagnostic`, { differences, cached: pair.cached });
  return state;
};
const key = async (name) => {
  const characters = { Enter: "\r", Escape: "\u001b", PageUp: "\uf72c", ArrowDown: "\uf701", ArrowUp: "\uf700" };
  assert.ok(Object.hasOwn(characters, name), `unsupported local key ${name}`);
  const sent = await run(`return ac.shell.devTypeKeys("w1", ${JSON.stringify(characters[name])}, 5);`);
  assert.equal(sent.length, 1, `${name} delivered to w1's first responder`);
};
const type = async (text, accept = (state) => state.typed === text) => {
  await run(`const h = globalThis.__omniboxNative; let prefix = "";
    return Array.from(${JSON.stringify(text)}).reduce((chain, ch) => chain.then(() => { prefix += ch; return h.type(prefix); }), h.clear()).then(() => true);`);
  return observe(`query ${JSON.stringify(text)}`, accept);
};
const activate = (id) => run(`const s = ac.store.getState(); s.closePanel("w1"); s.activate(${JSON.stringify(id)}); return true;`);
const open = async (surface) => {
  current = surface;
  await activate("a");
  await run(`ac.store.getState().updateSettings({ addressBar: ${JSON.stringify(surface.addressBar)}, commandBarPlacement: "field", newTabOpens: "commandBar" }); return true;`);
  await nativeWindow("base tab selected", (window) => window?.selectedTabId === "a");
  if (surface.addressBar === "sidebar") {
    await nativeWindow("sidebar address field mounted", (window) => window?.sidebarAddressBar?.inWindow === true);
  }
  await until("native address anchor ready", () => run(`return acPerf.findFibers("NativeOmniboxBar", 30).some((f) => {
    const props = f.memoizedProps;
    const panel = props.panel && JSON.parse(props.panel);
    return props.tabId === "a" && panel && !panel.open && panel.ready && (panel.variant ?? "panel") === ${JSON.stringify(surface.addressBar === "sidebar" ? "sidebar" : "panel")};
  });`));
  const press = surface.newTab ? { key: "t", keyCode: 17, modifiers: ["command"] } : { key: "l", keyCode: 37, modifiers: ["command"] };
  const result = await run(`return ac.shell.devKeyEquivalent("w1", ${JSON.stringify(press)});`);
  assert.ok(!result?.error, JSON.stringify(result));
  await until("native bar mounted", () => run(`
    const f = acPerf.findFibers("NativeOmniboxBar", 30).find((f) => f.memoizedProps.variant === ${JSON.stringify(surface.variant)} && !f.memoizedProps.idle && !!f.memoizedProps.opensTab === ${surface.newTab});
    if (!f) return false;
    for (let hook = f.memoizedState; hook; hook = hook.next) {
      const handle = hook.memoizedState?.current;
      if (typeof handle?.driverState === "function") { globalThis.__omniboxNative = handle; return true; }
    }
    return false;
  `));
  return observe(`${surface.name} opened`, (state) => surface.newTab
    ? state.typed === "" && state.value === "" && state.selected === -1 && isDeepStrictEqual(state.items.map((row) => row.tabId), ["b"])
    : state.typed === state.value && /^http:\/\/127\.0\.0\.1:\d+\/start$/.test(state.value)
      && isDeepStrictEqual(state.selection, { start: 0, end: state.value.length }));
};
const check = async (name, fn) => {
  if (!await rep.check(name, fn)) throw new Error(`stopping after ${name}`);
  if (openLoads !== null) assert.equal(requests.get("/open"), openLoads, "switch target never reloads");
};

try {
  await new Promise((done, reject) => { server.once("error", reject); server.listen(0, "127.0.0.1", done); });
  const base = `http://127.0.0.1:${server.address().port}`;
  const historyUrl = `${base}/history`;
  const bookmarkUrl = `${base}/bookmark`;
  const historyPrefix = `${base.slice("http://".length)}/his`;
  const fixture = session({
    windows: [{ id: "w1", activeTabIds: { default: "a" }, frame: [80, 80, 1280, 900] }],
    tabs: [{ id: "a", url: `${base}/start`, title: "Omni Local Fixture", lastActiveAt: 1 }, { id: "b", url: `${base}/open`, title: "Omni Open Fixture", lastActiveAt: 2 }],
    settings: { developerMode: { default: { on: [], off: ["127.0.0.1"], reload: "reload" } }, tabLayout: "sidebar", searchSuggestions: false, searchEngine: "custom", customSearchUrl: `${base}/search?q=%s`,
      customSearchEngines: [{ id: "fixture", name: "Fixture", keyword: "fixture", url: `${base}/scoped?q=%s` }],
      newTabOpens: "commandBar", addressBar: "toolbar", commandBarPreference: "website", warnBeforeClosingLastTab: false, warnBeforeClosingWindow: false },
  });
  budget = setTimeout(() => {
    rep.record("100-second run budget", { error: new Error("deadline exceeded") });
    void stop(1);
  }, 100000);
  launching = launch(appPath, { data: join(scratch, "data"), session: fixture, onboarded: true, probe: true,
    startTimeout: 25000, ready: { timeout: 20000, test: "return !!ac.store && !!ac.omnibox && !!globalThis.acPerf" },
    env: { SOLARA_NATIVE_SHELL: "1", SOLARA_NATIVE_OMNIBOX: "1", SOLARA_NATIVE_NEWTAB: "1" },
    files: { "bench-offline": "1" } });
  instance = await launching;
  assert.ok(!stopping, "launch interrupted");
  await check("fixture native catalogs are ready", async () => {
    await until("fixture bookmark root", () => run(`return !!ac.store.getState().bookmarks.roots.default?.bar;`));
    await run(`const s = ac.store.getState(); s.importHistory("default", [{ url: ${JSON.stringify(historyUrl)}, title: "Omni History Fixture", visits: 30, lastVisit: Date.now() }]);
      return ac.bookmarks.addBookmark({ profileId: "default", url: ${JSON.stringify(bookmarkUrl)}, title: "Omni Bookmark Fixture", parentId: s.bookmarks.roots.default.bar }).then(() => true);`);
    const counts = await until("native fixture catalogs", () => run(`const n = globalThis.expo.modules.SolaraSettings;
      return Promise.all([n.devHistorySnapshot(""), n.devBookmarksSnapshot("")]);`),
    ([history, bookmarks]) => history.ready && history.count >= 1 && bookmarks.ready && bookmarks.count >= 1, 7000);
    await nativeWindow("fixture tabs loaded", (window, state) => window?.tabIds.includes("b") && state.tabs.some((tab) => tab.id === "b" && tab.title === "Omni Open Fixture"));
    await run(`ac.store.getState().activate("b"); return true;`);
    await nativeWindow("switch target selected for loading", (window) => window?.selectedTabId === "b");
    await until("switch target load finished", () => run(`const s = ac.store.getState(); return s.tabs.b?.url === ${JSON.stringify(`${base}/open`)} && s.tabs.b?.title === "Omni Open Fixture" && s.live.b?.isLoading === false;`),
      (loaded) => loaded && (requests.get("/open") ?? 0) > 0);
    await run(`ac.store.getState().activate("a"); return true;`);
    await nativeWindow("fixture start tab selected", (window) => window?.selectedTabId === "a");
    openLoads = requests.get("/open") ?? 0;
    assert.ok(openLoads > 0, "switch target reached the fixture server");
    return counts;
  });
  for (const surface of [
    { name: "panel Cmd-L", variant: "panel", addressBar: "toolbar", newTab: false },
    { name: "sidebar Cmd-L", variant: "sidebar", addressBar: "sidebar", newTab: false },
    { name: "New Tab Cmd-T panel", variant: "panel", addressBar: "toolbar", newTab: true },
  ]) {
    await check(`${surface.name}: ${surface.newTab ? "focus and initial rows" : "focus and URL selection"}`, async () => {
      const state = await open(surface);
      if (surface.newTab) {
        assert.deepEqual(state.items.map((row) => row.tabId), ["b"]);
        assert.equal(state.selected, -1);
        assert.equal(state.value, "");
      } else {
        assert.equal(state.value, `${base}/start`);
        assert.deepEqual(state.selection, { start: 0, end: state.value.length });
      }
    });
    await check(`${surface.name}: eight structural query cases with native model lists`, async () => {
      const history = await type(historyPrefix, (state) => state.typed === historyPrefix && state.items.some((row) => row.url === historyUrl && row.visited));
      assert.equal(history.items[0].kind, "page");
      assert.equal(history.items[0].url, historyUrl);
      assert.equal(history.items[0].visited, true);
      assert.equal(history.completion, "tory");
      assert.equal(history.value, `${historyPrefix}tory`);
      assert.deepEqual(history.selection, { start: historyPrefix.length, end: historyPrefix.length + 4 });
      const text = await type("omnifixture unmatched words");
      assert.equal(text.items[0].kind, "search");
      assert.equal(text.items[0].url, `${base}/search?q=omnifixture%20unmatched%20words`);
      assert.equal(text.completion, "");
      const tab = await type("Omni Open Fixture");
      assert.ok(tab.items.slice(0, 3).some((row) => row.tabId === "b"), "open tab offers Switch to Tab near the top");
      assert.equal(tab.completion, "");
      const bookmark = await type("Omni Bookmark Fixture", (state) => state.typed === "Omni Bookmark Fixture" && state.items.some((row) => row.url === bookmarkUrl && row.bookmarked));
      assert.ok(bookmark.items.slice(0, 3).some((row) => row.url === bookmarkUrl && row.bookmarked), "bookmark ranks near the top");
      assert.equal(bookmark.completion, "");
      const forced = await type(`? ${historyPrefix}`);
      assert.ok(forced.items.every((row) => row.kind === "search"));
      assert.equal(forced.items[0].query, historyPrefix);
      assert.equal(forced.completion, "");
      const scope = await type("fixture ", (state) => state.scope?.engineId === "fixture");
      assert.equal(scope.scope.kind, "engine");
      assert.equal(scope.typed, "");
      await run(`return globalThis.__omniboxNative.type("scoped words").then(() => true);`);
      const scoped = await observe("scoped search", (state) => state.typed === "scoped words");
      assert.equal(scoped.items[0].url, `${base}/scoped?q=scoped%20words`);
      assert.equal(scoped.completion, "");
      await key("Escape");
      await observe("Escape leaves scope first", (state) => state.scope === null);
      const calc = await type("6 * 7");
      assert.ok(calc.items.some((row) => row.kind === "calc" && row.value === "42"));
      const bang = await type("!g cats");
      assert.equal(bang.items[0].kind, "search");
      assert.equal(bang.items[0].bang, true);
      assert.equal(bang.items[0].engine, "Google");
      assert.equal(bang.items[0].query, "cats");
      assert.equal(bang.completion, "");
    });
    await check(`${surface.name}: selected switch row switches without navigation or creation`, async () => {
      const loadsBefore = requests.get("/open");
      assert.equal(loadsBefore, openLoads);
      let state = await type("Omni Open Fixture", (state) => state.typed === "Omni Open Fixture" && state.items.some((row) => row.tabId === "b"));
      assert.ok(state.items.some((row) => row.tabId === "b"));
      assert.ok(state.items.length > 1, "switch fixture offers multiple keyboard-selectable rows");
      const typedValue = state.typed + state.completion;
      await key("PageUp");
      await observe("PageUp selects the first row", (state) => state.selected === 0);
      await key("ArrowDown");
      const filled = await observe("Down advances the selected row and fills the input", (state) => state.selected === 1 && state.value === shownFor(state));
      assert.equal(filled.typed, "Omni Open Fixture", "the typed text is kept while arrowing");
      assert.equal(filled.value, fillOf(filled.items[1]) || typedValue, "the input follows the highlight");
      await key("ArrowUp");
      state = await observe("Up returns to the first row and restores the typed text", (state) => state.selected === 0 && state.value === typedValue);
      await key("ArrowDown");
      await observe("Down fills again", (state) => state.selected === 1 && state.value === shownFor(state));
      await key("Escape");
      state = await observe("the first Escape restores the typed text and keeps the bar", (state) => state.selected === 0 && state.value === typedValue);
      const index = state.items.findIndex((row) => row.tabId === "b");
      assert.ok(index >= 0, "switch target remains in the current native list");
      for (let i = 0; i < index; i++) {
        await key("ArrowDown");
        await observe(`Down selects row ${i + 1}`, (state) => state.selected === i + 1);
      }
      await observe("switch row selected and its address in the input", (state) => state.selected === index && state.items[state.selected]?.tabId === "b"
        && (index === 0 ? state.value === typedValue : state.value === fillOf(state.items[index])));
      await key("Enter");
      await nativeWindow("switch landed", (window, snapshot) => window?.selectedTabId === "b" && isDeepStrictEqual([...window.tabIds].sort(), ["a", "b"])
        && isDeepStrictEqual(snapshot.tabs.map(({ id, url }) => ({ id, url })).sort((a, b) => a.id.localeCompare(b.id)),
          [{ id: "a", url: `${base}/start` }, { id: "b", url: `${base}/open` }]));
      for (const end = Date.now() + 500; Date.now() < end; await sleep(40)) {
        assert.ok(instance.stillOwned(), "switch target observation: instance exited");
        assert.equal(requests.get("/open"), loadsBefore, "switching does not request b's page again");
      }
    });
    await check(`${surface.name}: Enter navigates with the intended tab disposition`, async () => {
      await open(surface);
      const completed = await type(historyPrefix, (state) => state.typed === historyPrefix && state.items.some((row) => row.url === historyUrl && row.visited));
      const completedValue = completed.typed + completed.completion;
      assert.notEqual(completedValue, historyPrefix, "the history row completes inline");
      await key("ArrowDown");
      const searchRow = await observe("Down fills the search row's query", (state) => state.selected === 1 && state.items[1]?.kind === "search");
      assert.equal(searchRow.value, searchRow.items[1].query, "the input shows the highlighted search's query, without the inline completion");
      assert.equal(searchRow.typed, historyPrefix);
      await key("ArrowUp");
      await observe("Up restores the typed text and its inline completion", (state) => state.selected === 0 && state.value === completedValue && state.completion === completed.completion);
      await key("Enter");
      await nativeWindow("Enter landed", (window, snapshot) => {
        const tab = snapshot.tabs.find((tab) => tab.id === window?.selectedTabId);
        return tab?.url === historyUrl && (surface.newTab ? window.tabIds.length === 3 && tab.id !== "a" : window.tabIds.length === 2 && tab.id === "a");
      });
      await run(`const s = ac.store.getState(); for (const id of s.windows.w1.tabIds) if (id !== "a" && id !== "b") s.closeTab(id);
        s.navigate("a", ${JSON.stringify(`${base}/start`)}); s.activate("a"); return true;`);
      await nativeWindow("fixture restored", (window, snapshot) => window?.tabIds.length === 2 && snapshot.tabs.some((tab) => tab.id === "a" && tab.url === `${base}/start`));
    });
    await check(`${surface.name}: Escape and outside blur discard edits and restore`, async () => {
      await open(surface);
      await type("discarded omnifixture words");
      await key("Escape");
      await until("Escape dismissed", () => run(`return !ac.store.getState().windowUi.w1.panel.open;`));
      const reopened = await open(surface);
      assert.equal(reopened.typed, surface.newTab ? "" : `${base}/start`);
      await type("blurred omnifixture words");
      const click = await run(`return ac.shell.devClick("w1", { x: 1100, y: 840 });`);
      assert.ok(!click?.error, JSON.stringify(click));
      await until("outside blur dismissed", () => run(`return !ac.store.getState().windowUi.w1.panel.open;`));
      await nativeWindow("dismissal preserves page", (window, snapshot) => window?.selectedTabId === "a" && window.tabIds.length === 2
        && snapshot.tabs.some((tab) => tab.id === "a" && tab.url === `${base}/start`));
      const restored = await open(surface);
      assert.equal(restored.typed, surface.newTab ? "" : `${base}/start`);
    });
  }
} catch (error) {
  rep.record("run", { error });
} finally {
  try { await cleanup(); } catch (error) { rep.record("cleanup", { error }); }
  if (openLoads !== null && requests.get("/open") !== openLoads) rep.record("switch target reloaded", { error: new Error("fixture request count changed") });
}
const passed = rep.summary() && !stopping;
if (!keep && passed) rmSync(scratch, { recursive: true, force: true });
process.exit(stopping ? process.exitCode || 1 : passed ? 0 : 1);

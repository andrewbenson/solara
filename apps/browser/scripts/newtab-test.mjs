#!/usr/bin/env node
import assert from "node:assert/strict";
import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { createServer } from "node:http";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { isDeepStrictEqual } from "node:util";
import { launch, reporter, session, sleep } from "../../../scripts/lib/instance.mjs";

const HELP = `Checks the native New Tab hero in one hidden fixture instance.

  node apps/browser/scripts/newtab-test.mjs <Debug Solara.app> [--keep-data] [--placement=top|bottom|below-current]

Checks placeholder creation, repeat and discard, placement, first-edit settlement, initial focus with
an in-process key dispatch, per-tab text and selection after remount,
two-window/profile isolation, and Enter navigation in place. Uses loopback pages, disables remote
suggestions, and cross-checks the JS driver against the native model items, field editor and
native app snapshot. Teardown has a separate 10-second deadline. It does not verify SwiftUI row rendering or accessibility exposure. Defaults AC_UITEST_WAIT to 0; an occupied UI gate fails fast.
Requires native observationVersion 2 hooks (mounted, fieldAttached, listAway and editor state).
An explicit placement changes both settings after launch; the default exercises the launch settings.
Retains before/after Enter state and failed hero observation samples in hero-observations.json.`;
const args = process.argv.slice(2);
if (args.includes("--help") || args.includes("-h")) {
  console.log(HELP);
  process.exit(0);
}
const appArg = args.find((arg) => !arg.startsWith("--"));
const placementArgs = args.filter((arg) => arg.startsWith("--placement="));
const placement = placementArgs[0]?.slice("--placement=".length) ?? null;
const placements = new Map([["top", ["top", "top"]], ["bottom", ["bottom", "bottom"]], ["below-current", ["nextToCurrent", "bottom"]]]);
if (!appArg || placementArgs.length > 1 || (placement !== null && !placements.has(placement)) || args.some((arg) => arg.startsWith("--") && arg !== "--keep-data" && !arg.startsWith("--placement="))) {
  console.error(HELP);
  process.exit(2);
}
const appPath = resolve(appArg);
assert.ok(!appPath.startsWith("/Applications/") && !appPath.includes("/build-vista/"), "pass an isolated Debug build");
const keep = args.includes("--keep-data");
if (keep) process.env.AC_KEEP_DATA = "1";
process.env.AC_UITEST_WAIT ??= "0";
const scratch = mkdtempSync(join(tmpdir(), "ac-newtab-"));
const data = join(scratch, "data");
const rep = reporter(join(scratch, "newtab-test.log"), { name: "newtab-test" });
const observationsFile = join(scratch, "hero-observations.json");
const diagnostics = [];
const retainObservation = (entry) => {
  diagnostics.push(entry);
  writeFileSync(observationsFile, JSON.stringify(diagnostics, null, 2));
};
let app = null;
let launching = null;
let cleaning = null;
let stopping = false;
let failed = false;
let watchdog = null;
const server = createServer((req, res) => {
  const title = req.url === "/aster" ? "Fixture Aster" : req.url === "/beryl" ? "Fixture Beryl" : "Entered in place";
  res.writeHead(200, { "content-type": "text/html", "cache-control": "no-store" });
  res.end(`<!doctype html><title>${title}</title><link rel="icon" href="data:,"><body>${title}</body>`);
});
const cleanup = () => cleaning ??= (async () => {
  const deadline = setTimeout(() => {
    rep.record("cleanup deadline", { error: new Error("newtab-test cleanup exceeded 10 seconds") });
    process.exit(1);
  }, 10_000);
  try {
    const closed = server.listening ? new Promise((done) => server.close(done)) : Promise.resolve();
    server.closeAllConnections();
    try {
      const owned = app ?? await launching?.catch(() => null);
      if (owned) await owned.quit({ graceful: false });
    } finally {
      await closed;
    }
  } finally {
    clearTimeout(deadline);
    clearTimeout(watchdog);
  }
})();
const stop = async (code, reason) => {
  stopping = true;
  failed = true;
  process.exitCode = code;
  console.error(reason);
  try { await cleanup(); } catch (error) { rep.record("cleanup", { error }); }
  process.exit(code);
};
for (const [signal, code] of [["SIGINT", 130], ["SIGTERM", 143], ["SIGHUP", 129]]) {
  process.once(signal, () => void stop(code, `newtab-test received ${signal}`));
}
watchdog = setTimeout(() => void stop(1, "newtab-test exceeded 100 seconds"), 100_000);
const HELPERS = `
const S = () => ac.store.getState();
const heroFiber = (w, t) => acPerf.findFibers("NativeNewTabHero", 50).find((f) => f.memoizedProps?.windowId === w && f.memoizedProps?.tabId === t);
const heroRef = (w, t) => {
  const f = heroFiber(w, t);
  for (let hook = f?.memoizedState; hook; hook = hook.next) {
    const value = hook.memoizedState?.current;
    if (value && typeof value.driverState === "function") return value;
  }
  return null;
};
`;
const run = (body, timeout = 4000) => {
  assert.ok(!stopping, "test is stopping");
  return app.eval(`${HELPERS}\n${body}`, { timeout });
};
const until = async (what, sample, accept, ms = 4500) => {
  const end = Date.now() + ms;
  let last;
  do {
    if (!app.stillOwned()) throw new Error(`instance exited while waiting for ${what}`);
    if (end - Date.now() < 1000) break;
    last = await sample(end);
    if (Date.now() < end && await accept(last, end) && Date.now() < end) return last;
    await sleep(80);
  } while (Date.now() < end);
  throw new Error(`${what}: ${JSON.stringify(last)}`);
};
const chromeTab = (tabId) => run(`return globalThis.expo.modules.SolaraCEF.tabStrips().then((transaction) => transaction.strips.flatMap((strip) => strip.tabs).find((tab) => tab.key === ${JSON.stringify(tabId)}) ?? null);`, 1000);
const view = (w, t, end) => {
  if (end - Date.now() < 1000) return null;
  return run(`const ref = heroRef(${JSON.stringify(w)}, ${JSON.stringify(t)}); return ref ? ref.driverState().then(JSON.parse).then((native) => ({ native, js: ac.omnibox.get(${JSON.stringify(`${w}:hero`)})?.state() ?? null })) : null;`, 1000);
};
const snapshot = (what, accept) => until(what, () => app.snapshot({}, { timeout: 1000 }), (state, end) => state.consistent && accept(state, end));
const checkedView = async (w, t, text, { focused = true, title = null, absentTitle = null, compareJS = false } = {}) => {
  const mismatches = (state) => {
    if (!state?.native) return ["native hero missing"];
    const n = state.native;
    assert.equal(n.observationVersion, 2, "rebuild with observationVersion 2 native hooks");
    const failures = [];
    if (n.typed !== text) failures.push("typed");
    if (!n.mounted) failures.push("mounted");
    if (!n.fieldAttached) failures.push("field attached");
    if (n.listAway !== false) failures.push("list away");
    if (!Array.isArray(n.items)) failures.push("native items missing");
    if (n.windowId !== w || n.tabId !== t || n.profileId !== (w === "w1" ? "default" : "work") || n.variant !== "hero") failures.push("native identity");
    if (focused && n.focused !== true) failures.push("field focus");
    if (focused && n.fieldValue !== n.value) failures.push("field value");
    if (focused && !isDeepStrictEqual(n.fieldSelection, n.selection)) failures.push("field selection");
    if (compareJS || title) {
      if (!state.js || state.js.windowId !== w || state.js.tabId !== t || state.js.profileId !== n.profileId) failures.push("JS identity");
      if (state.js?.typed !== text) failures.push("JS typed");
      if (!isDeepStrictEqual(n.items, state.js?.items)) failures.push("JS/native items");
      if (n.value !== state.js?.value) failures.push("JS/native value");
      if (!isDeepStrictEqual(n.selection, state.js?.selection)) failures.push("JS/native selection");
    }
    if (title && (!Array.isArray(n.items) || !n.items.some((item) => item.title === title))) failures.push("expected title missing");
    if (absentTitle && Array.isArray(n.items) && n.items.some((item) => item.title === absentTitle)) failures.push("other profile title");
    return failures;
  };
  let found;
  const observations = [];
  let failures = ["no observation"];
  try {
    await until(`${w} native hero, selection and focus`, () => app.snapshot({}, { timeout: 1000 }), async (state, end) => {
      found = await view(w, t, end);
      failures = mismatches(found);
      if (!state.consistent) failures.push("snapshot inconsistent");
      const window = state.windows.find((entry) => entry.id === w);
      if (!window || window.selectedTabId !== t) failures.push(`selected tab ${window?.selectedTabId ?? "missing"}`);
      if (focused && !/NSTextView|NSTextField|FieldEditor|TextField/.test(window?.firstResponder ?? "")) failures.push(`first responder ${window?.firstResponder ?? "missing"}`);
      observations.push({ at: Date.now(), failures, hero: found, snapshot: state });
      return failures.length === 0;
    });
  } catch (error) {
    const evidence = { windowId: w, tabId: t, expected: { text, focused, title, absentTitle, compareJS }, observations };
    retainObservation({ stage: "failed hero check", ...evidence });
    rep.log("hero check observations", evidence);
    rep.log("hero wait error", error);
    rep.say("Hero diagnostics:", observationsFile);
    throw new Error(`${w}/${t} native hero: ${failures.join(", ")}`, { cause: error });
  }
  return found.native;
};
const observeEnter = async (stage) => {
  const state = await run(`return Promise.all([["w1", "a"], ["w2", "b"]].map(([windowId, tabId]) => {
    const ref = heroRef(windowId, tabId);
    return (ref ? ref.driverState().then(JSON.parse) : Promise.resolve(null)).then((native) => ({
      windowId, tabId, native, js: ac.omnibox.get(windowId + ":hero")?.state() ?? null
    }));
  })).then((heroes) => {
    const s = S();
    return { heroes, settings: { newTabPosition: s.settings.newTabPosition, newTabButtonPosition: s.settings.newTabButtonPosition },
      focusedWindowId: s.ui.focusedWindowId, windows: s.windows, tabs: s.tabs };
  });`);
  const evidence = { stage, placement, at: Date.now(), state, snapshot: await app.snapshot({}, { timeout: 1000 }) };
  retainObservation(evidence);
  rep.log("Enter observation", evidence);
};
const editorKey = async (key, keyCode, modifiers = []) => {
  const press = await run(`return ac.shell.devKeyEquivalent("w1", ${JSON.stringify({ key, keyCode, modifiers, send: true, asKey: true, wait: 30 })});`);
  assert.ok(!press?.error, JSON.stringify(press));
  assert.equal(press.handledBy, "sent");
  assert.match(press.firstResponder, /NSTextView|FieldEditor/);
};
const type = async (w, t, text) => {
  await run(`const d = ac.omnibox.get(${JSON.stringify(`${w}:hero`)}); if (!heroRef(${JSON.stringify(w)}, ${JSON.stringify(t)}) || !d) throw new Error("missing hero driver"); d.clear(); return true;`);
  await checkedView(w, t, "");
  await run(`ac.omnibox.get(${JSON.stringify(`${w}:hero`)}).type(${JSON.stringify(text)}); return true;`);
  return checkedView(w, t, text, { compareJS: true });
};
const activate = async (w, t) => {
  await run(`S().activate(${JSON.stringify(t)}); return true;`);
  await until(`${w}/${t} mounted`, () => run(`return !!heroRef(${JSON.stringify(w)}, ${JSON.stringify(t)});`), Boolean);
  await snapshot(`${w}/${t} selected`, (state) => state.windows.some((entry) => entry.id === w && entry.selectedTabId === t));
};
const check = async (name, body) => {
  if (!(await rep.check(name, body))) throw new Error(`stopping after ${name}`);
};

try {
  await new Promise((done, reject) => { server.once("error", reject); server.listen(0, "127.0.0.1", done); });
  const base = `http://127.0.0.1:${server.address().port}`;
  const fixture = session({
    profiles: ["Personal", "Work"],
    windows: [
      { id: "w1", profileId: "default", frame: [80, 80, 1100, 800], activeTabIds: { default: "a" } },
      { id: "w2", profileId: "work", frame: [100, 100, 1100, 800], activeTabIds: { work: "b" } },
    ],
    tabs: [
      { id: "a", windowId: "w1", url: "", title: "" },
      { id: "c", windowId: "w1", url: "", title: "" },
      { id: "pa", windowId: "w1", url: `${base}/aster`, title: "Fixture Aster" },
      { id: "b", windowId: "w2", url: "", title: "" },
      { id: "pb", windowId: "w2", url: `${base}/beryl`, title: "Fixture Beryl" },
    ],
    settings: { newTabOpens: "page", addressBar: "toolbar", commandBarPlacement: "field", searchSuggestions: false, warnBeforeClosingLastTab: false, warnBeforeClosingWindow: false },
  });
  launching = launch(appPath, { data, fresh: true, onboarded: true, probe: true, session: fixture, files: { "bench-offline": "" },
    env: { SOLARA_NATIVE_SHELL: "1", SOLARA_NATIVE_NEWTAB: "1", SOLARA_NATIVE_OMNIBOX: "1" },
    ready: false, startTimeout: 20_000 });
  app = await launching;
  assert.ok(!stopping, "launch interrupted");
  await app.ready({ timeout: 20_000, test: "return !!ac.store.getState().windows.w2 && !!globalThis.acPerf && ac.omnibox.ids().includes('w1:hero') && ac.omnibox.ids().includes('w2:hero')" });
  if (placement !== null) {
    const [newTabPosition, newTabButtonPosition] = placements.get(placement);
    const settings = { newTabPosition, newTabButtonPosition };
    await run(`S().updateSettings(${JSON.stringify(settings)}); return true;`);
    await until("explicit placement applied after launch", () => run(`return { newTabPosition: S().settings.newTabPosition, newTabButtonPosition: S().settings.newTabButtonPosition };`), (state) => isDeepStrictEqual(state, settings));
  }

  await check("Cmd-T opens a fresh hero with its native field focused", async () => {
    await run(`S().activate("pa"); return true;`);
    await snapshot("page selected before Cmd-T", (state) => state.windows.some((w) => w.id === "w1" && w.selectedTabId === "pa"));
    const ids = await run(`return Object.keys(S().tabs).sort();`);
    const press = await run(`return ac.shell.devKeyEquivalent("w1", { key: "t", keyCode: 17, modifiers: ["command"] });`);
    assert.ok(!press?.error, JSON.stringify(press));
    const opened = await until("fresh tab selected", () => run(`const s = S(); const id = s.windows.w1.activeTabIds.default; return id && !${JSON.stringify(ids)}.includes(id) && s.tabs[id]?.url === "" ? id : null;`), Boolean);
    await checkedView("w1", opened, "");
    assert.equal(await run(`return S().tabs[${JSON.stringify(opened)}]?.newTabPlaceholder;`), true, "Cmd-T selects an untouched placeholder");
    const live = await until("the untouched placeholder is a real Chrome tab", () => chromeTab(opened), (tab) => !!tab?.browser);
    const order = await run(`return S().windows.w1.tabIds;`);
    const position = await run(`return S().settings.newTabPosition;`);
    if (position === "top") assert.equal(order[0], opened, "placeholder keeps the top insertion slot");
    else if (position === "nextToCurrent") assert.equal(order[order.indexOf("pa") + 1], opened, "placeholder follows the current tab");
    else assert.equal(order.at(-1), opened, "placeholder keeps the bottom insertion slot");
    await run(`return ac.shell.devTypeKeys("w1", "opened by command", 5);`);
    await checkedView("w1", opened, "opened by command", { compareJS: true });
    assert.notEqual(await run(`return S().tabs[${JSON.stringify(opened)}]?.newTabPlaceholder;`), true, "typing settles the same tab before navigation");
    assert.equal((await chromeTab(opened))?.browser, live.browser, "typing retains the same Chrome tab");
    assert.equal(await run(`return Object.keys(S().tabs).length;`), ids.length + 1);
    await run(`S().closeTab(${JSON.stringify(opened)}); S().activate("a"); return true;`);
    await checkedView("w1", "a", "");
    return { opened, keyRoute: press.handledBy };
  });

  await check("switching away discards an untouched placeholder without adding a reopen entry", async () => {
    const before = await run(`S().activate("pa"); return { ids: Object.keys(S().tabs).sort(), closed: S().closedTabs.map((t) => t.id) };`);
    const opened = await run(`return S().newTab("w1", { newTabCommand: true });`);
    await checkedView("w1", opened, "");
    await until("the discard fixture has a real Chrome tab", () => chromeTab(opened), (tab) => !!tab?.browser);
    await run(`S().activate("pa"); return true;`);
    await snapshot("untouched placeholder discarded", (state) => !state.tabs.some((tab) => tab.id === opened) && state.windows.some((window) => window.id === "w1" && window.selectedTabId === "pa"));
    const after = await run(`return { ids: Object.keys(S().tabs).sort(), closed: S().closedTabs.map((t) => t.id) };`);
    assert.deepEqual(after, before);
    await until("discard closes the real Chrome tab", () => chromeTab(opened), (tab) => tab === null);
    await activate("w1", "a");
    return { discarded: opened, closed: after.closed };
  });

  await check("a repeated Cmd-T settles the old empty tab and selects a fresh placeholder", async () => {
    await run(`S().activate("pa"); return true;`);
    const first = await run(`return S().newTab("w1", { newTabCommand: true });`);
    await checkedView("w1", first, "");
    await run(`return ac.shell.devKeyEquivalent("w1", { key: "t", keyCode: 17, modifiers: ["command"] });`);
    const second = await until("second placeholder selected", () => run(`const s = S(); const id = s.windows.w1.activeTabIds.default; return id !== ${JSON.stringify(first)} && s.tabs[id]?.newTabPlaceholder === true ? id : null;`), Boolean);
    await checkedView("w1", second, "");
    const retained = await run(`return S().tabs[${JSON.stringify(first)}];`);
    assert.ok(retained, "the first empty tab stays in the list");
    assert.equal(retained.url, "");
    assert.notEqual(retained.newTabPlaceholder, true);
    await run(`S().activate("pa"); return true;`);
    await snapshot("only the fresh untouched placeholder discarded", (state) => state.tabs.some((tab) => tab.id === first) && !state.tabs.some((tab) => tab.id === second));
    await run(`S().closeTab(${JSON.stringify(first)}); S().activate("a"); return true;`);
    await checkedView("w1", "a", "");
    return { settled: first, discarded: second };
  });

  await check("opening New Tab focuses the native field and receives local key events", async () => {
    await checkedView("w1", "a", "");
    await checkedView("w2", "b", "");
    await run(`return ac.shell.devTypeKeys("w1", "draft alpha", 5);`);
    const state = await checkedView("w1", "a", "draft alpha", { compareJS: true });
    assert.equal(state.completion, "");
    return { typed: state.typed, selection: state.selection };
  });

  await check("each New Tab saves its own text and selection across a real unmount and remount", async () => {
    await run(`globalThis.__newtabTestRef = heroRef("w1", "a"); return globalThis.__newtabTestRef.applyMenu("selectAll").then(() => true);`);
    await editorKey("\uf702", 123, ["function"]);
    await editorKey("\uf703", 124, ["function"]);
    await editorKey("\uf703", 124, ["function"]);
    for (let i = 0; i < 5; i++) await editorKey("\uf703", 124, ["shift", "function"]);
    const before = await checkedView("w1", "a", "draft alpha");
    assert.deepEqual(before.selection, { start: 2, end: 7 });
    assert.deepEqual(before.fieldSelection, { start: 2, end: 7 });
    await activate("w1", "c");
    await until("a's hero unmounted", () => run(`return !heroFiber("w1", "a");`), Boolean);
    await checkedView("w1", "c", "");
    await type("w1", "c", "draft gamma");
    await activate("w1", "a");
    const restored = await checkedView("w1", "a", "draft alpha");
    assert.deepEqual(restored.selection, { start: 2, end: 7 });
    assert.deepEqual(restored.fieldSelection, { start: 2, end: 7 });
    assert.equal(await run(`return heroRef("w1", "a") !== globalThis.__newtabTestRef;`), true, "new native view handle after remount");
    await activate("w1", "c");
    await checkedView("w1", "c", "draft gamma");
    return { a: restored.typed, c: "draft gamma", selection: restored.selection };
  });

  await check("two windows retain independent native hero edits", async () => {
    await type("w2", "b", "draft beta");
    await checkedView("w1", "c", "draft gamma");
    await checkedView("w2", "b", "draft beta");
    await activate("w1", "a");
    await checkedView("w1", "a", "draft alpha");
    await checkedView("w2", "b", "draft beta");
    const state = await snapshot("two profile windows", (value) => value.windows.some((w) => w.id === "w1" && w.profileId === "default") && value.windows.some((w) => w.id === "w2" && w.profileId === "work"));
    return state.windows.map(({ id, profileId, selectedTabId }) => ({ id, profileId, selectedTabId }));
  });

  await check("profile A and B result items remain isolated in the mounted native models", async () => {
    await type("w1", "a", "Fixture");
    const a = await checkedView("w1", "a", "Fixture", { title: "Fixture Aster", absentTitle: "Fixture Beryl" });
    assert.ok(a.items.some((item) => item.tabId === "pa"), "A offers its own open tab");
    assert.ok(a.items.every((item) => item.tabId !== "pb"), "B's open tab never reaches A");
    await type("w2", "b", "Fixture");
    const b = await checkedView("w2", "b", "Fixture", { title: "Fixture Beryl", absentTitle: "Fixture Aster" });
    assert.ok(b.items.some((item) => item.tabId === "pb"), "B offers its own open tab");
    assert.ok(b.items.every((item) => item.tabId !== "pa"), "A's open tab never reaches B");
    await checkedView("w1", "a", "Fixture", { title: "Fixture Aster", absentTitle: "Fixture Beryl" });
    return { a: a.items, b: b.items };
  });

  await check("Enter from the hero navigates its existing tab in place", async () => {
    const destination = `${base}/entered`;
    await type("w1", "a", destination);
    const before = await run(`return Object.keys(S().tabs).sort();`);
    await observeEnter("before");
    await run(`return ac.shell.devKeyEquivalent("w1", { key: "\\r", keyCode: 36, modifiers: [], send: true, asKey: true, wait: 30 });`);
    await until("same tab navigated", () => run(`return { url: S().tabs.a?.url, ids: Object.keys(S().tabs).sort(), selected: S().windows.w1.activeTabIds.default };`), (state) => state.url === destination && state.selected === "a");
    assert.deepEqual(await run(`return Object.keys(S().tabs).sort();`), before);
    await snapshot("native in-place navigation", (state) => state.tabs.some((t) => t.id === "a" && t.url === destination && t.profileId === "default") && state.windows.some((w) => w.id === "w1" && w.selectedTabId === "a" && w.tabIds.length === 3));
    await observeEnter("after in-place navigation");
    await checkedView("w2", "b", "Fixture", { title: "Fixture Beryl", absentTitle: "Fixture Aster" });
    return { tabId: "a", url: destination, tabCount: before.length };
  });
} catch (error) {
  failed = true;
  rep.record("newtab-test aborted", { error });
} finally {
  try { await cleanup(); } catch (error) { failed = true; rep.record("cleanup", { error }); }
  if (!keep && !stopping && !failed && !rep.failed.length) rmSync(data, { recursive: true, force: true });
}
const passed = rep.summary();
process.exit(stopping ? process.exitCode || 1 : passed && !failed ? 0 : 1);

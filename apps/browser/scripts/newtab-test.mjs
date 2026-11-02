#!/usr/bin/env node
import assert from "node:assert/strict";
import { mkdtempSync, rmSync } from "node:fs";
import { createServer } from "node:http";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { isDeepStrictEqual } from "node:util";
import { launch, reporter, session, sleep } from "../../../scripts/lib/instance.mjs";

const HELP = `Checks the native New Tab hero in one hidden fixture instance.

  node apps/browser/scripts/newtab-test.mjs <Debug Solara.app> [--keep-data]

Checks initial focus with an in-process key dispatch, per-tab text and selection after remount,
two-window/profile isolation, and Enter navigation in place. Uses loopback pages, disables remote
suggestions, and cross-checks the JS driver against the native model items, field editor and
native app snapshot. Teardown has a separate 10-second deadline. It does not verify SwiftUI row rendering or accessibility exposure. Defaults AC_UITEST_WAIT to 0; an occupied UI gate fails fast.
Requires native observationVersion 2 hooks (mounted, fieldAttached, listAway and editor state).`;
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
assert.ok(!appPath.startsWith("/Applications/") && !appPath.includes("/build-vista/"), "pass an isolated Debug build");
const keep = args.includes("--keep-data");
if (keep) process.env.AC_KEEP_DATA = "1";
process.env.AC_UITEST_WAIT ??= "0";
const scratch = mkdtempSync(join(tmpdir(), "ac-newtab-"));
const data = join(scratch, "data");
const rep = reporter(join(scratch, "newtab-test.log"), { name: "newtab-test" });
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
const view = (w, t, end) => {
  if (end - Date.now() < 1000) return null;
  return run(`const ref = heroRef(${JSON.stringify(w)}, ${JSON.stringify(t)}); return ref ? ref.driverState().then(JSON.parse).then((native) => ({ native, js: ac.omnibox.get(${JSON.stringify(`${w}:hero`)})?.state() ?? null })) : null;`, 1000);
};
const snapshot = (what, accept) => until(what, () => app.snapshot({}, { timeout: 1000 }), (state, end) => state.consistent && accept(state, end));
const checkedView = async (w, t, text, { focused = true, title = null, absentTitle = null, compareJS = false } = {}) => {
  const valid = (state) => {
    if (!state?.native || state.native.typed !== text) return false;
    const n = state.native;
    assert.equal(n.observationVersion, 2, "rebuild with observationVersion 2 native hooks");
    if (!n.mounted || !n.fieldAttached || n.listAway !== false || !Array.isArray(n.items)) return false;
    if (n.windowId !== w || n.tabId !== t || n.profileId !== (w === "w1" ? "default" : "work") || n.variant !== "hero") return false;
    if (focused && (n.focused !== true || n.fieldValue !== n.value || !isDeepStrictEqual(n.fieldSelection, n.selection))) return false;
    if ((compareJS || title) && (!state.js || state.js.windowId !== w || state.js.tabId !== t || state.js.profileId !== n.profileId || state.js.typed !== text || !isDeepStrictEqual(n.items, state.js.items) || n.value !== state.js.value || !isDeepStrictEqual(n.selection, state.js.selection))) return false;
    if (title && !n.items.some((item) => item.title === title)) return false;
    if (absentTitle && n.items.some((item) => item.title === absentTitle)) return false;
    return true;
  };
  let found;
  await snapshot(`${w} native hero, selection and focus`, async (state, end) => {
    found = await view(w, t, end);
    return valid(found) && state.windows.some((entry) => entry.id === w && entry.selectedTabId === t && (!focused || /NSTextView|NSTextField|FieldEditor|TextField/.test(entry.firstResponder ?? "")));
  });
  return found.native;
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

  await check("Cmd-T opens a fresh hero with its native field focused", async () => {
    await run(`S().activate("pa"); return true;`);
    await snapshot("page selected before Cmd-T", (state) => state.windows.some((w) => w.id === "w1" && w.selectedTabId === "pa"));
    const ids = await run(`return Object.keys(S().tabs).sort();`);
    const press = await run(`return ac.shell.devKeyEquivalent("w1", { key: "t", keyCode: 17, modifiers: ["command"] });`);
    assert.ok(!press?.error, JSON.stringify(press));
    const opened = await until("fresh tab selected", () => run(`const s = S(); const id = s.windows.w1.activeTabIds.default; return id && !${JSON.stringify(ids)}.includes(id) && s.tabs[id]?.url === "" ? id : null;`), Boolean);
    await checkedView("w1", opened, "");
    await run(`return ac.shell.devTypeKeys("w1", "opened by command", 5);`);
    await checkedView("w1", opened, "opened by command", { compareJS: true });
    assert.equal(await run(`return Object.keys(S().tabs).length;`), ids.length + 1);
    await run(`S().closeTab(${JSON.stringify(opened)}); S().activate("a"); return true;`);
    await checkedView("w1", "a", "");
    return { opened, keyRoute: press.handledBy };
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
    await run(`return ac.shell.devTypeKeys("w1", "\\r", 5);`);
    await until("same tab navigated", () => run(`return { url: S().tabs.a?.url, ids: Object.keys(S().tabs).sort(), selected: S().windows.w1.activeTabIds.default };`), (state) => state.url === destination && state.selected === "a");
    assert.deepEqual(await run(`return Object.keys(S().tabs).sort();`), before);
    await snapshot("native in-place navigation", (state) => state.tabs.some((t) => t.id === "a" && t.url === destination && t.profileId === "default") && state.windows.some((w) => w.id === "w1" && w.selectedTabId === "a" && w.tabIds.length === 3));
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

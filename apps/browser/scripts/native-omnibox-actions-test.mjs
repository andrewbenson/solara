import assert from "node:assert/strict";
import { mkdirSync, writeFileSync } from "node:fs";
import { createServer } from "node:http";
import { join, resolve } from "node:path";
import { launch, reporter, session, sleep } from "../../../scripts/lib/instance.mjs";

const [appArg, outputArg, ...rest] = process.argv.slice(2);
assert.ok(appArg && outputArg && rest.length === 0, "usage: node native-omnibox-actions-test.mjs <Debug app> <fresh output directory>");
const appPath = resolve(appArg);
assert.ok(!appPath.startsWith("/Applications/") && !appPath.includes("/build-vista/"), "use a scratch Debug app");
const output = resolve(outputArg);
mkdirSync(output, { recursive: false });
const rep = reporter(join(output, "native-omnibox-actions.log"), { name: "native-omnibox-actions" });
const evidence = [];
const requests = new Map();
const server = createServer((req, res) => {
  requests.set(req.url, (requests.get(req.url) ?? 0) + 1);
  res.writeHead(200, { "content-type": "text/html", "cache-control": "no-store" });
  res.end(`<!doctype html><title>Omnibox ${req.url}</title><link rel="icon" href="data:,"><body>Omnibox action fixture</body>`);
});
let app;
let launching;
let clipboard;
let budget;
let cleanupPromise;
let stopped = false;
const cleanup = () => cleanupPromise ??= (async () => {
  const deadline = setTimeout(() => process.exit(1), 10000);
  try {
    const owned = app ?? await launching?.catch(() => null);
    if (owned) {
      if (clipboard !== undefined && owned.stillOwned()) {
        await owned.eval(`globalThis.nativeModuleProxy.Clipboard.setString(${JSON.stringify(clipboard)}); return true;`, { timeout: 1000 }).catch(() => {});
      }
      await owned.quit({ graceful: false });
    }
    server.closeAllConnections();
    await new Promise((done) => server.listening ? server.close(done) : done());
  } finally {
    clearTimeout(budget);
    clearTimeout(deadline);
  }
})();
const stop = async (code) => {
  stopped = true;
  await cleanup().catch(() => {});
  process.exit(code);
};
for (const [signal, code] of [["SIGINT", 130], ["SIGTERM", 143], ["SIGHUP", 129]]) process.once(signal, () => void stop(code));
const run = (source, timeout = 2000) => {
  assert.ok(!stopped && app?.stillOwned(), "owned instance exited");
  return app.eval(source, { timeout });
};
const until = async (name, read, accept = Boolean, timeout = 6000) => {
  const end = Date.now() + timeout;
  let last;
  while (Date.now() + 1000 < end) {
    assert.ok(app?.stillOwned(), `${name}: owned instance exited`);
    last = await read();
    if (accept(last)) return last;
    await sleep(40);
  }
  throw new Error(`${name}: deadline exceeded: ${JSON.stringify(last)}`);
};
const snapshot = () => app.snapshot({}, { timeout: 1000 });
const native = async (name, accept) => {
  const value = await until(name, snapshot, (state) => state.consistent && accept(state, state.windows.find((w) => w.id === "w1")));
  evidence.push({ name, snapshot: value });
  return value;
};
const bar = () => run("return globalThis.__nativeActionBar.driverState().then(JSON.parse);", 1000);
const setClipboard = (text) => run(`globalThis.nativeModuleProxy.Clipboard.setString(${JSON.stringify(text)}); return true;`);
const getClipboard = () => run("return globalThis.nativeModuleProxy.Clipboard.getString();");
const chromeTab = (tabId) => run(`return globalThis.expo.modules.SolaraCEF.tabStrips().then((transaction) => transaction.strips.flatMap((strip) => strip.tabs).find((tab) => tab.key === ${JSON.stringify(tabId)}) ?? null);`, 1000);
const acquire = async (variant, tabId, focus = true) => {
  await until(`${variant} native field attached`, () => run(`
    const name = ${JSON.stringify(variant)} === "hero" ? "NativeNewTabHero" : "NativeOmniboxBar";
    const f = acPerf.findFibers(name, 200).find(f => f.memoizedProps.tabId === ${JSON.stringify(tabId)}
      && (${JSON.stringify(variant)} === "hero" || f.memoizedProps.variant === ${JSON.stringify(variant)} && !f.memoizedProps.idle));
    if (!f) return false;
    for (let h = f.memoizedState; h; h = h.next) {
      const handle = h.memoizedState?.current;
      if (typeof handle?.driverState === "function") { globalThis.__nativeActionBar = handle; return true; }
    }
    return false;
  `));
  if (focus) await run("return globalThis.__nativeActionBar.focus().then(() => true);");
  const value = await until(`${variant} native ownership`, bar, (state) => state.tabId === tabId && state.variant === variant && state.focused && state.fieldAttached && state.nativeActions === true);
  evidence.push({ name: `${variant} ownership`, bar: value });
  return value;
};
const open = async (surface) => {
  if (surface === "hero") {
    const id = await run('const s = ac.store.getState(); s.closePanel("w1"); s.updateSettings({newTabOpens:"page"}); return s.newTab("w1");');
    await native("hero selected", (_, w) => w?.selectedTabId === id);
    await acquire("hero", id);
    return id;
  }
  await run(`const s = ac.store.getState(); s.closePanel("w1"); s.activate("a");
    s.updateSettings({addressBar:${JSON.stringify(surface === "sidebar" ? "sidebar" : "toolbar")},newTabOpens:"commandBar",commandBarPlacement:${JSON.stringify(surface === "panel" ? "centred" : "field")}});
    s.openPanel("w1", ""); return true;`);
  await acquire(surface === "sidebar" ? "sidebar" : "panel", "a");
  return "a";
};
const type = async (text, accept = (value) => value.typed === text) => {
  await run(`return globalThis.__nativeActionBar.clear().then(() => globalThis.__nativeActionBar.type(${JSON.stringify(text)})).then(() => true);`);
  return until(`query ${text}`, bar, accept);
};
const key = (name, mods = {}) => run(`return globalThis.__nativeActionBar.key(${JSON.stringify(name)},${JSON.stringify(mods)}).then(() => true);`);
const menu = (choice) => run(`return globalThis.__nativeActionBar.applyMenu(${JSON.stringify(choice)}).then(() => true);`);
const enter = () => run(`return ac.shell.devTypeKeys("w1", ${JSON.stringify("\r")}, 5);`);
const commandRow = async (text, command) => {
  const value = await type(text, (state) => state.items.some((row) => row.kind === "action" && row.id === command));
  const index = value.items.findIndex((row) => row.kind === "action" && row.id === command);
  await key("PageUp");
  for (let row = 0; row < index; row++) await key("ArrowDown");
  await until(`${command} row selected`, bar, (state) => state.items[state.selected]?.kind === "action" && state.items[state.selected]?.id === command);
  await enter();
};
const clean = async (base) => {
  await run(`const s = ac.store.getState(); s.closePanel("w1"); s.setDownloadsOpen("w1",false);
    for (const id of [...s.windowOrder]) if (id !== "w1") s.closeWindow(id);
    for (const id of [...s.windows.w1.tabIds]) if (id !== "a" && id !== "b") s.closeTab(id);
    s.navigate("a",${JSON.stringify(`${base}/start?utm_source=fixture&keep=yes`)}); s.activate("a"); return true;`);
  await native("fixture restored", (state, w) => w?.selectedTabId === "a" && w.tabIds.length === 2 && state.windows.length === 1);
};
const assertNoJS = async () => {
  const state = await run("return ac.omnibox.actions.state();");
  assert.deepEqual(state, { disabled: true, received: {}, executed: {} }, "native actions emit no JavaScript fallback action callbacks");
};
const check = async (name, fn) => {
  if (!await rep.check(name, async () => { await fn(); await assertNoJS(); })) throw new Error(`stopping after ${name}`);
};

try {
  await new Promise((done, reject) => { server.once("error", reject); server.listen(0, "127.0.0.1", done); });
  const base = `http://127.0.0.1:${server.address().port}`;
  budget = setTimeout(() => { rep.record("five-minute run budget", { error: new Error("deadline exceeded") }); void stop(1); }, 300000);
  const launchFixture = (data, env = {}) => launch(appPath, {
    data: join(output, data), fresh: true, onboarded: true, probe: true, keepData: true,
    env: { SOLARA_NATIVE_SHELL: "1", SOLARA_NATIVE_OMNIBOX: "1", SOLARA_NATIVE_NEWTAB: "1", ...env },
    session: session({ windows: [{ id: "w1", activeTabIds: { default: "a" }, frame: [80, 80, 1280, 900] }],
      tabs: [{ id: "a", url: `${base}/start?utm_source=fixture&keep=yes`, title: "Omni Start" }, { id: "b", url: `${base}/switch`, title: "Omni Switch Target" }],
      settings: { developerMode: { default: { on: [], off: ["127.0.0.1"], reload: "reload" } }, searchSuggestions: false, searchEngine: "custom", customSearchUrl: `${base}/search?q=%s`, commandBarPreference: "search", addressBar: "toolbar", newTabOpens: "commandBar",
        warnBeforeClosingLastTab: false, warnBeforeClosingWindow: false, warnBeforeClosingTabs: false } }),
    files: { "bench-offline": "1" },
    ready: "return !!globalThis.acPerf && !!ac.omnibox?.actions;",
  });
  launching = launchFixture("data");
  app = await launching;
  clipboard = await getClipboard();
  await run("ac.omnibox.actions.disableJS(true); ac.omnibox.actions.reset(); return true;");
  for (const addressBar of ["toolbar", "sidebar"]) {
    for (const placement of ["field", "centred"]) {
      await check(`native ${addressBar} address press uses ${placement} placement`, async () => {
        await run(`const s = ac.store.getState(); s.closePanel("w1"); s.activate("a");
          s.updateSettings({addressBar:${JSON.stringify(addressBar)},commandBarPlacement:${JSON.stringify(placement)},
            developerMode:{default:{on:[],off:["127.0.0.1"],reload:"reload"}}}); return true;`);
        const accepted = await run('return globalThis.expo.modules.SolaraOmniboxBar.devAddressPress("w1","a");');
        assert.equal(accepted, true, "the real Swift address action accepts the press");
        const variant = addressBar === "sidebar" && placement === "field" ? "sidebar" : "panel";
        const model = await acquire(variant, "a", false);
        assert.equal(model.nativeActions, true);
        const observed = await native("native address press presents the configured omnibox", (_, window) => window?.panelOpen === true
          && window.omnibox?.open === true && window.omnibox.focused === true && window.omnibox.variant === variant
          && window.omnibox.source === (placement === "centred" ? "panel" : "anchor"));
        evidence.push({ name: "address press placement", addressBar, placement, model,
          omnibox: observed.windows.find((window) => window.id === "w1").omnibox });
        await key("Escape");
        await native("address press Escape closes the panel", (_, window) => window?.panelOpen === false);
        await clean(base);
      });
    }
  }
  for (const surface of ["panel", "sidebar", "toolbar", "hero"]) {
    await check(`${surface}: Return URL and search`, async () => {
      let id = await open(surface);
      await type(`${base}/${surface}-url`);
      await enter();
      await native("Return URL landed", (s, w) => w?.selectedTabId === id && s.tabs.some((t) => t.id === id && t.url === `${base}/${surface}-url`));
      await clean(base);
      id = await open(surface);
      await type(`${surface} search fixture`);
      await enter();
      await native("Return search landed", (s, w) => w?.selectedTabId === id && s.tabs.some((t) => t.id === id && t.url === `${base}/search?q=${surface}%20search%20fixture`));
      await clean(base);
    });
    await check(`${surface}: command-shift Return searches the typed address`, async () => {
      const id = await open(surface);
      const typed = `${base}/${surface}-verbatim`;
      await type(typed);
      await key("Enter", { metaKey: true, shiftKey: true });
      await native("verbatim search landed", (s, w) => w?.selectedTabId === id
        && s.tabs.some((t) => t.id === id && t.url === `${base}/search?q=${encodeURIComponent(typed)}`));
      await clean(base);
    });
    for (const [label, mods, disposition] of [
      ["command", { metaKey: true }, "newTab"],
      ["option", { altKey: true }, "newTab"],
      ["shift", { shiftKey: true }, "newWindow"],
      ["option-shift", { altKey: true, shiftKey: true }, "backgroundTab"],
    ]) {
      await check(`${surface}: ${label} Return`, async () => {
        const id = await open(surface);
        const before = await snapshot();
        const url = `${base}/${surface}-${label}`;
        await type(url);
        await key("Enter", mods);
        await native("modified Return landed", (s, w) => {
          const added = s.tabs.find((t) => !before.tabs.some((b) => b.id === t.id) && t.url === url);
          if (!added) return false;
          if (disposition === "newWindow") return w?.selectedTabId === id && w.panelOpen === false
            && s.windows.some((n) => n.id === added.windowId && !before.windows.some((b) => b.id === n.id)
              && n.selectedTabId === added.id);
          return added.windowId === "w1" && w?.selectedTabId === (disposition === "backgroundTab" ? id : added.id);
        });
        await clean(base);
      });
    }
    await check(`${surface}: selected suggestion switches without navigation`, async () => {
      await run('ac.store.getState().activate("b"); return true;');
      await native("switch fixture loaded", (s, w) => w?.selectedTabId === "b" && s.tabs.some((t) => t.id === "b" && t.title === "Omnibox /switch"));
      const loads = requests.get("/switch");
      await open(surface);
      const state = await type("Omnibox /switch", (v) => v.items.some((row) => row.tabId === "b"));
      const index = state.items.findIndex((row) => row.tabId === "b");
      await key("PageUp");
      for (let row = 0; row < index; row++) await key("ArrowDown");
      await until("switch row selected", bar, (v) => v.items[v.selected]?.tabId === "b");
      await enter();
      await native("switch selected", (_, w) => w?.selectedTabId === "b");
      assert.equal(requests.get("/switch"), loads, "switch keeps the existing WebContents");
      await clean(base);
    });
    await check(`${surface}: native clipboard and Escape`, async () => {
      let id = await open(surface);
      await setClipboard(`${base}/paste?utm_source=fixture&keep=yes`);
      await menu("pasteAndGo");
      await native("paste URL landed", (s) => s.tabs.some((t) => t.id === id && t.url === `${base}/paste?keep=yes`));
      await clean(base);
      id = await open(surface);
      await setClipboard(`${surface} pasted query`);
      await menu("pasteAndGo");
      await native("paste search landed", (s) => s.tabs.some((t) => t.id === id && t.url === `${base}/search?q=${surface}%20pasted%20query`));
      await clean(base);
      if (surface !== "hero") {
        await open(surface);
        await menu("copyURL");
        assert.equal(await getClipboard(), `${base}/start?keep=yes`, "Copy URL strips trackers");
      }
      await open(surface);
      await type("escape fixture words");
      await key("Escape");
      if (surface === "hero") await until("hero Escape clears text", bar, (v) => v.typed === "");
      else await until("Escape closes panel", () => run('return !ac.store.getState().windowUi.w1.panel.open;'));
      await clean(base);
    });
  }
  for (const addressBar of ["toolbar", "sidebar"]) {
    await check(`developer ${addressBar}: native URL editor Return and Escape`, async () => {
      await run(`const s = ac.store.getState(); s.updateSettings({addressBar:${JSON.stringify(addressBar)},commandBarPlacement:"field",
        developerMode:{default:{on:["127.0.0.1"],off:[],reload:"reload"}}}); return true;`);
      const focusDeveloper = async () => {
        const sent = await run('return ac.shell.devKeyEquivalent("w1", {key:"l",keyCode:37,modifiers:["command"]});');
        assert.ok(!sent?.error, JSON.stringify(sent));
        const focused = await until("native developer URL field", () => app.snapshot({ windowId: "w1", shortcuts: true }, { timeout: 1000 }), (state) => {
          const window = state.windows.find((w) => w.id === "w1");
          return state.consistent && window?.panelOpen === false && window.shortcutFields?.some((field) => String(field.value).includes(`${base}/`));
        });
        evidence.push({ name: `developer ${addressBar} native field`, snapshot: focused });
      };
      await focusDeveloper();
      const url = `${base}/developer-${addressBar}`;
      await run(`return ac.shell.devTypeKeys("w1", ${JSON.stringify(`${url}\r`)}, 5);`);
      await native("developer Return landed", (state, window) => window?.selectedTabId === "a" && state.tabs.some((tab) => tab.id === "a" && tab.url === url));
      await focusDeveloper();
      await run(`return ac.shell.devTypeKeys("w1", ${JSON.stringify("discarded developer text\u001b")}, 5);`);
      await native("developer Escape preserves URL", (state, window) => window?.selectedTabId === "a" && window.panelOpen === false
        && state.tabs.some((tab) => tab.id === "a" && tab.url === url));
      await run('ac.store.getState().updateSettings({developerMode:{default:{on:[],off:["127.0.0.1"],reload:"reload"}}}); return true;');
      await clean(base);
    });
  }
  await check("Command Bar tab, window and private window rows use native actions", async () => {
    for (const [text, command] of [["New Tab", "newTab"], ["New Window", "newWindow"], ["New Incognito Window", "newIncognitoWindow"]]) {
      await open("panel");
      const before = await snapshot();
      await commandRow(text, command);
      const landed = await native(`${command} landed`, (s, w) => command !== "newTab"
        ? s.windows.some((n) => !before.windows.some((b) => b.id === n.id))
        : w?.selectedTabId !== "a" && s.tabs.some((t) => !before.tabs.some((b) => b.id === t.id)));
      if (command === "newIncognitoWindow") {
        const created = landed.windows.find((window) => !before.windows.some((old) => old.id === window.id));
        assert.equal(await run(`return ac.store.getState().windows[${JSON.stringify(created.id)}]?.incognito;`), true, "private command creates a private store window");
      }
      await clean(base);
    }
  });
  await check("Command Bar History and Bookmarks rows open their internal pages", async () => {
    for (const [text, command, url] of [["History", "showHistory", "solara://history"], ["Bookmarks", "manageBookmarks", "solara://bookmarks"]]) {
      await open("panel");
      await commandRow(text, command);
      await native(`${command} selected its page`, (state, window) => state.tabs.some((tab) => tab.id === window?.selectedTabId && tab.url === url));
      await clean(base);
    }
  });
  await check("Command Bar Downloads row opens the native downloads overlay", async () => {
    await open("panel");
    await commandRow("Downloads", "downloads");
    await native("Downloads overlay presented", (_, window) => window?.overlays?.some((overlay) => overlay.kind === "downloads"));
    await clean(base);
  });
  await check("New Tab Command Bar Return navigates its into target in place", async () => {
    const id = await run(`const s = ac.store.getState(); s.closePanel("w1"); s.updateSettings({newTabOpens:"commandBar"});
      const id = s.newTab("w1",{newTabCommand:true}); s.openPanel("w1","",{kind:"into",tabId:id}); return id;`);
    await native("into target selected", (_, window) => window?.selectedTabId === id);
    const model = await acquire("panel", id);
    assert.equal(model.opensTab, true, "the native bar is opening into a New Tab target");
    const before = await snapshot();
    const initial = await run(`return ac.store.getState().tabs[${JSON.stringify(id)}]?.newTabPlaceholder ?? null;`);
    if (initial !== null) assert.equal(initial, true, "ntph42 provides an untouched placeholder before Return");
    const chromeBefore = await chromeTab(id);
    const url = `${base}/newtab-into-target`;
    await type(url);
    await enter();
    await native("into target navigated without another tab", (state, window) => window?.selectedTabId === id
      && state.tabs.length === before.tabs.length && state.tabs.some((tab) => tab.id === id && tab.url === url));
    const chromeAfter = await until("into target owns a Chrome tab", () => chromeTab(id), (tab) => !!tab?.browser);
    if (chromeBefore?.browser) assert.equal(chromeAfter.browser, chromeBefore.browser, "Return retains the existing Chrome tab");
    if (initial === true) assert.notEqual(await run(`return ac.store.getState().tabs[${JSON.stringify(id)}]?.newTabPlaceholder ?? null;`), true, "navigation settles the placeholder");
    evidence.push({ name: "New Tab into target identity", id, placeholderBefore: initial, chromeBefore, chromeAfter });
    await clean(base);
  });
  await check("developer retirement blur keeps production routing to outgoing A", async () => {
    await app.quit({ graceful: false });
    launching = launchFixture("retirement-data", { SOLARA_NATIVE_WINDOW_LAYOUT: "1" });
    app = await launching;
    await run("ac.omnibox.actions.disableJS(true); ac.omnibox.actions.reset(); return true;");
    await clean(base);
    await run('const s = ac.store.getState(); s.updateSettings({addressBar:"toolbar",commandBarPlacement:"field",developerMode:{default:{on:["127.0.0.1"],off:[],reload:"reload"}}}); return true;');
    await run('return ac.shell.devKeyEquivalent("w1", {key:"l",keyCode:37,modifiers:["command"]});');
    await until("developer editor attached for retirement", () => app.snapshot({ windowId: "w1", shortcuts: true }, { timeout: 1000 }),
      (state) => state.consistent && state.windows.find((w) => w.id === "w1")?.shortcutFields?.some((field) => String(field.value).includes(`${base}/`)));
    const draft = "outgoing A field-editor draft";
    const routed = await run(`return globalThis.expo.modules.SolaraOmniboxBar.devRetireDeveloperURL("w1","a","b",${JSON.stringify(draft)}).then(JSON.parse);`);
    assert.equal(routed.accepted, true, JSON.stringify(routed));
    assert.equal(routed.activeBeforeProjection, "b");
    assert.equal(routed.activeAfterProjection, "b", "retirement never reactivates A");
    assert.equal(routed.replaced, true, "the real pane projection retires A's editor");
    assert.deepEqual(routed.sent, [{ windowId: "w1", tabId: "a", id: "urlEdit", kind: "blur", text: draft, activeTabId: "b" }],
      "the real onToolbarClick/router reaches the tab-id-capturing send exactly once, including repeated detach/held-blur flush");
    await native("retirement preserves B selection and both URLs", (state, window) => window?.selectedTabId === "b"
      && state.tabs.some((tab) => tab.id === "a" && tab.url === `${base}/start?utm_source=fixture&keep=yes`)
      && state.tabs.some((tab) => tab.id === "b" && tab.url === `${base}/switch`));
    evidence.push({ name: "developer retirement production route", routed });
    await run('ac.store.getState().updateSettings({developerMode:{default:{on:[],off:["127.0.0.1"],reload:"reload"}}}); return true;');
    await clean(base);
  });
} catch (error) {
  rep.record("run", { error });
} finally {
  writeFileSync(join(output, "evidence.json"), JSON.stringify(evidence, null, 2));
  await cleanup().catch((error) => rep.record("cleanup", { error }));
}
process.exitCode = rep.summary() && !stopped ? 0 : 1;

import { execFileSync, spawnSync } from "node:child_process";
import { cpSync, mkdirSync, rmSync, writeFileSync } from "node:fs";
import { createServer } from "node:http";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { parseArgs } from "node:util";
import assert from "node:assert/strict";
import { evaluate, quit } from "./perf/js-bench.mjs";
import { devtools, launch, sleep } from "../../../scripts/lib/instance.mjs";

const { values: flags, positionals } = parseArgs({ allowPositionals: true, options: { bundle: { type: "string" }, out: { type: "string" }, port: { type: "string" } } });
if (!positionals[0]) {
  console.error("usage: node hidden-pane-test.mjs <Solara.app> [--bundle <main.jsbundle>] [--out <dir>]");
  process.exit(2);
}
const out = resolve(flags.out ?? join(tmpdir(), "ac-hidden-pane"));
mkdirSync(out, { recursive: true });
let app = resolve(positionals[0]);
if (flags.bundle) {
  const clone = join(out, "app", "Solara.app");
  rmSync(dirname(clone), { recursive: true, force: true });
  mkdirSync(dirname(clone), { recursive: true });
  execFileSync("cp", ["-cR", app, clone]);
  cpSync(resolve(flags.bundle), join(clone, "Contents/Resources/main.jsbundle"));
  const identity = spawnSync("codesign", ["-dvv", app], { encoding: "utf8" }).stderr.match(/^Authority=(.+)$/m)?.[1] ?? "-";
  writeFileSync(`${clone}.entitlements.plist`, execFileSync("codesign", ["-d", "--entitlements", "-", "--xml", app], { encoding: "utf8" }));
  execFileSync("codesign", ["--force", "--sign", identity, "--timestamp=none", "--options", "runtime", "--entitlements", `${clone}.entitlements.plist`, clone], { stdio: "inherit" });
  app = clone;
}

const data = join(out, "data");
rmSync(data, { recursive: true, force: true });
const page = (name) => `data:text/html,<title>${name}</title><p>${name}-findme</p>`;
const tab = (id, url) => ({ id, url, title: id, favicon: null, pinned: false, muted: false, zoom: 1, customTitle: null, customIcon: null, pinnedUrl: null, navigation: null, openerId: null, createdAt: Date.now(), lastActiveAt: Date.now() });
const ids = ["a", "b", "c", "d"];
const fixture = {
    version: 2,
    profiles: { default: { id: "default", name: "Personal", color: "plum", icon: null, createdAt: 0 } },
    profileOrder: ["default"],
    orphanedProfileData: [],
    settings: { searchSuggestions: false, warnBeforeClosingLastTab: false, warnBeforeClosingWindow: false },
    windows: [{ id: "w1", profileId: "default", incognito: false, tabIds: ids, activeTabIds: { default: "a" }, sidebarOpen: true, frame: [100, 100, 1200, 800], createdAt: 0 }],
    windowOrder: ["w1"],
    focusedWindowId: "w1",
    tabs: ids.map((id) => ({ ...tab(id, page(`Tab-${id}`)), windowId: "w1", profileId: "default" })),
    groups: [],
    splits: [],
    closedTabs: [],
    closedWindows: [],
  };

const unfinished = new Set();
const stillLoading = createServer((req, res) => {
  const name = req.url.slice(1);
  res.writeHead(200, { "content-type": "text/html" });
  res.write(`<!doctype html><title>${name}</title><p>${name}-findme</p>`);
  unfinished.add(res);
});
await new Promise((r) => stillLoading.listen(0, "127.0.0.1", r));
const loadingPage = (name) => `http://127.0.0.1:${stillLoading.address().port}/${name}`;

const port = Number(flags.port ?? 9795);
const switches = {};
for (const part of (process.env.SOLARA_SWITCHES ?? "").split(",")) {
  const [name, value] = part.split("=").map((text) => text.trim());
  if (name && value) switches[name] = !["off", "0", "false"].includes(value);
}
const instance = await launch(app, {
  data, port, session: fixture, onboarded: true, ready: false, js: "none",
  env: { SOLARA_DRAW_WINDOWS: "1", ...(process.env.SOLARA_SWITCHES ? { SOLARA_SWITCHES: process.env.SOLARA_SWITCHES } : {}) },
  files: { "perf-probe": "", ...(process.env.SOLARA_SWITCHES ? { "switches-cache.json": { version: 1, switches } } : {}) },
});
const { pid } = instance;
const untilSnapshot = async (what, accept, ms = 8000) => {
  const end = Date.now() + ms;
  let last;
  do {
    if (!instance.alive) throw new Error(`${what}: the owned app exited`);
    if (end - Date.now() < 1000) break;
    last = await instance.snapshot({ windowId: "w1" }, { timeout: 1000 });
    assert.equal(last.schema, 1);
    if (Date.now() < end && last.consistent && await accept(last) && Date.now() < end) return last;
    await sleep(80);
  } while (Date.now() < end);
  throw new Error(`${what}: native snapshot never matched (${JSON.stringify(last)})`);
};
const askFromPage = async (urlPart, expression) => {
  const end = Date.now() + 8000;
  let target = null;
  while (!target && Date.now() < end) {
    const list = await fetch(`http://127.0.0.1:${port}/json/list`).then((r) => r.json(), () => []);
    target = list.find((t) => t.type === "page" && t.url.includes(urlPart)) ?? null;
    if (!target) await sleep(200);
  }
  if (!target) throw new Error(`no DevTools target for ${urlPart}`);
  const cdp = await devtools(target);
  try {
    await cdp.send("Runtime.evaluate", { expression, userGesture: true, returnByValue: true });
  } finally {
    cdp.close();
  }
};
const ac = (body, ms) => evaluate(data, pid, body, ms);
const results = [];
const check = (name, ok, detail = "") => {
  results.push(ok);
  console.log(`${ok ? "ok  " : "FAIL"} ${name}${detail ? `  (${detail})` : ""}`);
};
try {
  let ready = false;
  for (let i = 0; i < 60 && !ready; i++) ready = await ac("return !!ac.store.getState().windows.w1;", 2000).then((v) => v, () => false);
  if (!ready) throw new Error("the dev harness never answered");
  await ac(`
    globalThis.audit = {
      frames: (n) => new Promise((r) => { let k = n || 2; const step = () => (k-- > 0 ? requestAnimationFrame(step) : r()); step(); }),
      props: (name, tabId) => acPerf.findFibers(name, 500).filter((f) => !tabId || f.memoizedProps?.tabId === tabId || f.memoizedProps?.tab?.id === tabId).map((f) => ({ props: f.memoizedProps, rendered: !!f.child })),
      native: (tabId) => acPerf.findFibers("NativeToolbarView", 500).map((f) => { try { return JSON.parse(f.memoizedProps?.state ?? "null"); } catch { return null; } }).filter((n) => n && n.tabId === tabId),
      until: (test, ms) => new Promise((r) => { const end = Date.now() + (ms || 15000); const poll = () => (test() ? r(true) : Date.now() > end ? r(false) : setTimeout(poll, 50)); poll(); }),
    };
    return true;`);
  const S = "const S = () => ac.store.getState();";
  const initialSnapshot = await untilSnapshot("hosted capabilities", async (s) => {
    const nativePrompts = await ac(`return Promise.resolve(globalThis.expo.modules.SolaraHosted?.kinds?.() ?? []).then((k) => k.includes("panePrompts"));`);
    return Array.isArray(s.hostedKinds) && s.hostedKinds.includes("panePrompts") === nativePrompts && nativePrompts;
  });
  assert.ok(initialSnapshot.hostedKinds.includes("panePrompts"));

  const loaded = await ac(`${S}
    S().activate("b");
    return audit.until(() => S().tabs.b.title === "Tab-b" && ac.webviews.has("b"))
      .then(() => { S().activate("a"); return audit.frames(3); })
      .then(() => ({ b: ac.webviews.has("b"), shown: S().windows.w1.activeTabIds.default }));`, 60_000);
  check("tab B's pane stays mounted while hidden", loaded.b && loaded.shown === "a", JSON.stringify(loaded));
  const loadedSnapshot = await untilSnapshot("A remains selected", (s) => s.windows[0]?.selectedTabId === loaded.shown);
  assert.equal(loadedSnapshot.windows[0].selectedTabId, loaded.shown);

  const hiddenChanges = await ac(`${S}
    const url = ${JSON.stringify(loadingPage("HiddenLoad"))};
    S().updateTab("b", { navigation: { url, seq: Date.now() } });
    let ok = false;
    return audit.until(() => S().tabs.b.title === "HiddenLoad" && S().live.b?.isLoading).then((loadedIt) => {
      ok = loadedIt;
      S().updateTab("b", { zoom: 1.5 });
      S().setFind("b", { open: true, query: "findme" });
      return audit.frames(3);
    }).then(() => ({ ok, url: S().tabs.b.url, title: S().tabs.b.title, renderedB: audit.props("UrlField", "b").length + audit.native("b").length }));`, 60_000);
  check("a hidden tab loads what it's sent to (its own tab's navigation)", hiddenChanges.ok, `${hiddenChanges.url} "${hiddenChanges.title}"`);
  check("nothing of B's toolbar renders while it's hidden", hiddenChanges.renderedB === 0);
  const hiddenSnapshot = await untilSnapshot("hidden B navigation and zoom", (s) => s.tabs.some((t) => t.id === "b" && t.url === hiddenChanges.url && t.title === hiddenChanges.title && t.zoom === 1.5));
  const hiddenTab = hiddenSnapshot.tabs.find((t) => t.id === "b");
  assert.equal(hiddenTab.url, hiddenChanges.url);
  assert.equal(hiddenTab.title, hiddenChanges.title);
  assert.equal(hiddenTab.zoom, 1.5);
  await askFromPage("/HiddenLoad", "Notification.requestPermission(); true");
  await sleep(3000);
  const askedWhileHidden = await ac("return !!ac.pageState.getState().pages.b?.permission;");
  console.log(`note the request reached the store while B was hidden: ${askedWhileHidden}`);

  const shown = await ac(`${S}
    S().activate("b");
    const t = (f) => { try { return f(); } catch (e) { return "ERR " + e.message; } };
    const M = globalThis.expo.modules.SolaraMedia;
    const inPane = () => M.describePaneOverlays("w1").then((d) => { const p = JSON.parse(d)?.tabs?.b?.permission; return !!p && !p.hidden; });
    const paneWithin = (ms) => { const end = Date.now() + ms; const poll = () => inPane().then((on) => (on || Date.now() > end ? on : new Promise((r) => setTimeout(r, 100)).then(poll))); return poll(); };
    const drawn = () => paneWithin(8000);
    return audit.frames(3).then(drawn).then((paneShown) => ({
      nativeToolbarCount: audit.native("b").length,
      url: t(() => audit.props("UrlField", "b")[0]?.props.tab.url ?? audit.native("b").map((n) => n.url && n.url.host + n.url.hoverTrail)[0]),
      zoom: t(() => audit.props("ZoomIndicator", "b")[0]?.props.zoom ?? audit.native("b").map((n) => { const z = (n.url?.trailing ?? []).find((t) => t.id === "zoom"); return z ? Number(z.tooltip.match(/([0-9]+)%/)[1]) / 100 : 1; })[0]),
      loading: t(() => audit.props("ReloadButton", "b")[0]?.props.loading ?? audit.native("b").map((n) => (n.left ?? []).find((b) => b.id === "reload")?.icon === "xmark")[0]),
      find: t(() => audit.props("FindBar", "b")[0]?.rendered),
      prompt: t(() => paneShown && !audit.props("PermissionPrompt", "b").some((p) => p.rendered)),
    }));`);
  check("shown: the URL it loaded while hidden", typeof shown.url === "string" && shown.url.includes("HiddenLoad"), shown.url);
  check("shown: its zoom", shown.zoom === 1.5, String(shown.zoom));
  check("shown: loading", shown.loading === true, String(shown.loading));
  check("shown: the find bar opened while hidden", shown.find === true);
  check("shown: the permission prompt that came while hidden", shown.prompt === true);
  const shownSnapshot = await untilSnapshot("B shown with its native permission prompt", (s) => s.windows[0]?.selectedTabId === "b" && (!shown.nativeToolbarCount || !!s.windows[0]?.toolbarStates?.b) && s.windows[0]?.paneOverlays?.tabs?.b?.permission?.hidden === false);
  const shownTab = shownSnapshot.tabs.find((t) => t.id === "b");
  assert.ok(shownTab.url.includes("HiddenLoad"));
  assert.equal(shownTab.zoom, shown.zoom);
  if (shown.nativeToolbarCount) {
    const toolbar = shownSnapshot.windows[0].toolbarStates.b;
    assert.equal(toolbar.tabId, "b");
    assert.equal(toolbar.hidden, false);
    assert.equal(toolbar.reloadIcon === "xmark", shown.loading);
    assert.equal(Number(toolbar.zoomLabel.match(/([0-9]+)%/)[1]) / 100, shown.zoom);
  }
  assert.equal(!shownSnapshot.windows[0].paneOverlays.tabs.b.permission.hidden, shown.prompt);

  const panes = await ac(`${S}
    const want = () => S().windows.w1.tabIds.filter((id) => S().tabs[id]?.navigation || S().tabs[id]?.adoptId).sort().join(",");
    const have = () => [...ac.webviews.keys()].filter((id) => S().tabs[id]?.windowId === "w1").sort().join(",");
    const steps = [];
    let e;
    const settle = (name) => audit.until(() => want() === have(), 8000).then(() => steps.push([name, want(), have()]));
    e = S().newTab("w1", { url: ${JSON.stringify(page("Tab-e"))}, background: true });
    return settle("open")
      .then(() => { S().closeTab("c"); return settle("close"); })
      .then(() => { S().updateTab(e, { title: "Retitled" }); S().activate(e); return settle("switch"); })
      .then(() => steps);`, 60_000);
  for (const [step, want, have] of panes) check(`mounted panes after ${step}`, want === have, `want ${want} have ${have}`);
} finally {
  await quit(pid);
  for (const res of unfinished) res.destroy();
  stillLoading.close();
}
process.exit(results.every(Boolean) ? 0 : 1);

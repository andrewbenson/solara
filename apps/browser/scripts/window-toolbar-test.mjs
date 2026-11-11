import { execFileSync, spawnSync } from "node:child_process";
import { cpSync, mkdirSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { parseArgs } from "node:util";
import { evaluate } from "./perf/js-bench.mjs";
import { launch, sleep } from "../../../scripts/lib/instance.mjs";

const { values: flags, positionals } = parseArgs({ allowPositionals: true, options: { bundle: { type: "string" }, out: { type: "string" }, port: { type: "string" } } });
if (!positionals[0]) {
  console.error("usage: node window-toolbar-test.mjs <Solara.app> [--bundle <main.jsbundle>] [--out <dir>] [--port 9796]");
  process.exit(2);
}
const out = resolve(flags.out ?? join(tmpdir(), "ac-window-toolbar"));
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
const page = (name, color) => `data:text/html,<title>${name}</title><meta name="theme-color" content="${color}"><p>${name}</p>`;
const tab = (id, url) => ({ id, url, title: id, favicon: null, pinned: false, muted: false, zoom: 1, customTitle: null, customIcon: null, pinnedUrl: null, navigation: null, openerId: null, createdAt: Date.now(), lastActiveAt: Date.now() });
const pages = { a: page("Tab-a", "#C0392B"), b: page("Tab-b", "#2471A3"), c: "https://example.com/c", d: "https://example.org/d" };
const ids = Object.keys(pages);
const fixture = {
    version: 2,
    profiles: { default: { id: "default", name: "Personal", color: "plum", icon: null, createdAt: 0 } },
    profileOrder: ["default"],
    orphanedProfileData: [],
    settings: { searchSuggestions: false, warnBeforeClosingLastTab: false, warnBeforeClosingWindow: false },
    windows: [{ id: "w1", profileId: "default", incognito: false, tabIds: ids, activeTabIds: { default: "a" }, sidebarOpen: true, frame: [100, 100, 1200, 800], createdAt: 0 }],
    windowOrder: ["w1"],
    focusedWindowId: "w1",
    tabs: ids.map((id) => ({ ...tab(id, pages[id]), windowId: "w1", profileId: "default" })),
    groups: [],
    splits: [],
    closedTabs: [],
    closedWindows: [],
};
const files = { "perf-probe": "" };
if (process.env.SOLARA_SWITCHES) {
  const switches = {};
  for (const part of process.env.SOLARA_SWITCHES.split(",")) {
    const [name, value] = part.split("=").map((value) => value.trim());
    if (name && value) switches[name] = !["off", "0", "false"].includes(value);
  }
  files["switches-cache.json"] = { version: 1, switches };
}
const instance = await launch(app, { data, port: Number(flags.port ?? 9796), session: fixture,
  onboarded: true, files, js: "live", ready: false,
  env: { SOLARA_DRAW_WINDOWS: "1", ...(process.env.SOLARA_SWITCHES ? { SOLARA_SWITCHES: process.env.SOLARA_SWITCHES } : {}) } });
const { pid } = instance;
const ac = (body, ms) => evaluate(data, pid, body, ms);
const untilSnapshot = async (what, accept, ms = 5000) => {
  const end = Date.now() + ms;
  let last;
  while (Date.now() < end) {
    last = await instance.snapshot({ windowId: "w1" }).catch((error) => ({ error: error.message }));
    if (!last.error && await accept(last)) return last;
    await sleep(50);
  }
  throw new Error(`${what}: native snapshot never matched (${JSON.stringify(last)})`);
};
const snapshotURL = (url) => url === "" ? null : url?.startsWith("data:") ? "data:" : url;
const sortedBars = (bars) => bars.map((bar) => [bar.tabId, bar.bare, bar.urlHost]).sort((a, b) => a[0].localeCompare(b[0]));
const nativeState = async (state) => {
  await untilSnapshot("toolbar tab ids, addresses and native host state", async (snapshot) => {
    const window = snapshot.windows[0];
    if (!window || window.selectedTabId !== state.active || JSON.stringify(window.tabIds) !== JSON.stringify(state.tabIds)) return false;
    const tabUrls = await ac(`return Object.fromEntries(${JSON.stringify(state.tabIds)}.map((id) => [id, ac.store.getState().tabs[id]?.url]));`);
    if (state.tabIds.some((id) => snapshot.tabs.find((tab) => tab.id === id)?.url !==
      snapshotURL(tabUrls[id]))) return false;
    return JSON.stringify(sortedBars(window.toolbarHosts)) === JSON.stringify(sortedBars(state.nativeToolbars));
  });
};
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
    globalThis.wt = {
      frames: (n) => new Promise((r) => { let k = n || 3; const step = () => (k-- > 0 ? requestAnimationFrame(step) : r()); step(); }),
      fibers: (name) => acPerf.findFibers(name, 500).filter((f) => f.memoizedProps),
      inPane: (f) => { for (let p = f.return; p; p = p.return) if (p.type?.type?.name === "TabPane" || p.type?.name === "TabPane" || p.elementType?.type?.name === "TabPane") return p.memoizedProps.tabId; return null; },
      state: () => {
        const toolbars = wt.fibers("Toolbar").map((f) => ({ tabId: f.memoizedProps.tabId, bare: !!f.memoizedProps.bare, windowToolbar: !!f.memoizedProps.windowToolbar, pane: wt.inPane(f) }));
        const auto = wt.fibers("AutoHideToolbar").map((f) => ({ tabId: f.memoizedProps.tabId, mode: f.memoizedProps.mode, pane: wt.inPane(f) }));
        const backdrops = [...wt.fibers("AutoHideBackdrop"), ...wt.fibers("ToolbarBackdrop"), ...wt.fibers("NativeAutoHide")].map((f) => ({ tabId: f.memoizedProps.tabId, pane: wt.inPane(f) }));
        const native = acPerf.findFibers("NativeToolbarView", 500).map((f) => { try { return JSON.parse(f.memoizedProps?.state ?? "null"); } catch { return null; } }).filter((n) => n?.tabId);
        const hosts = [...wt.fibers("UrlField").map((f) => f.memoizedProps.tab?.url), ...native.filter((n) => n.url?.host).map((n) => ac.store.getState().tabs[n.tabId]?.url)];
        const w = ac.store.getState().windows.w1;
        return { active: w.activeTabIds[w.profileId], hideToolbarWhileScrolling: ac.store.getState().settings.hideToolbarWhileScrolling, toolbars, auto, backdrops, hosts,
          tabIds: [...w.tabIds], tabUrls: Object.fromEntries(w.tabIds.map((id) => [id, ac.store.getState().tabs[id]?.url])),
          nativeToolbars: native.map((n) => ({ tabId: n.tabId, bare: !!n.bare, windowToolbar: !!n.windowToolbar, background: n.palette.background, hairline: n.hairline, stripes: n.stripes, urlHost: n.url?.host ?? null })) };
      },
      until: (test, ms) => new Promise((r) => { const end = Date.now() + (ms || 15000); const poll = () => (test() ? r(true) : Date.now() > end ? r(false) : setTimeout(poll, 50)); poll(); }),
    };
    return true;`);
  const S = "const S = () => ac.store.getState();";
  const switchTo = async (id) => {
    const state = await ac(`${S} acPerf.reset(); S().activate(${JSON.stringify(id)}); return wt.frames(4).then(() => ({ ...wt.state(), mounted: acPerf.read().mounts.Toolbar ?? 0 }));`);
    await nativeState(state);
    return state;
  };

  for (const mode of ["auto-hide", "always shown"]) {
    const autoHide = mode === "auto-hide";
    await ac(`${S} S().updateSettings({ hideToolbarWhileScrolling: ${autoHide} }); return wt.frames(4).then(() => true);`);
    await switchTo("a");
    for (const id of ["b", "c", "d", "a"]) {
      const st = await switchTo(id);
      const windowBars = st.toolbars.filter((t) => !t.pane);
      const nativeStatic = mode === "always shown" && windowBars[0]?.windowToolbar === true;
      const surface = nativeStatic ? !windowBars[0].bare && st.nativeToolbars.some((n) => n.tabId === id && n.windowToolbar && !n.bare && n.background === null && n.hairline === false && n.stripes === null) : windowBars[0]?.bare;
      const selectedMode = st.hideToolbarWhileScrolling === autoHide && (autoHide ? st.auto.length === 1 && st.auto[0].tabId === id && !st.auto[0].pane && st.auto[0].mode === "shown" : st.auto.length === 0);
      check(`${mode}: switching to ${id}, the window's one toolbar shows ${id}`, selectedMode && windowBars.length === 1 && windowBars[0].tabId === id && st.toolbars.length === 1 && surface, JSON.stringify({ hideToolbarWhileScrolling: st.hideToolbarWhileScrolling, auto: st.auto, toolbars: st.toolbars }));
      check(`${mode}: switching to ${id}, the toolbar is kept, not mounted again`, st.mounted === 0, `Toolbar mounts ${st.mounted}`);
      const url = await ac(`${S} return S().tabs[${JSON.stringify(id)}].url;`);
      check(`${mode}: switching to ${id}, the address field shows ${id}'s address`, st.hosts.length === 1 && st.hosts[0] === url, JSON.stringify(st.hosts));
      const backdrop = autoHide ? st.backdrops.length === 1 && st.backdrops[0].tabId === id && st.backdrops[0].pane === id : st.backdrops.length === 0;
      check(`${mode}: switching to ${id}, the frame surface belongs to ${id}'s toolbar`, backdrop, JSON.stringify(st.backdrops));
    }
  }
  await ac(`${S} S().updateSettings({ hideToolbarWhileScrolling: true }); return wt.frames(4).then(() => true);`);

  await switchTo("c");
  const collapsed = await ac(`${S} ac.toolbarAutoHide.noteScroll("c", { state: "down" }); return wt.frames(4).then(() => wt.state());`);
  await nativeState(collapsed);
  check("auto-hide: scrolling down collapses the window's bar for the shown tab", collapsed.auto.length === 1 && collapsed.auto[0].tabId === "c" && collapsed.auto[0].mode === "collapsed", JSON.stringify(collapsed.auto));
  const other = await switchTo("d");
  check("auto-hide: the next tab's bar is shown", other.auto[0]?.tabId === "d" && other.auto[0]?.mode === "shown", JSON.stringify(other.auto));
  const back = await switchTo("c");
  check("auto-hide: back on the scrolled tab, its bar is revealed", back.auto[0]?.tabId === "c" && back.auto[0]?.mode === "shown", JSON.stringify(back.auto));

  const opened = await ac(`${S} const id = S().newTab("w1"); return wt.frames(6).then(() => ({ id, ...wt.state() }));`);
  await nativeState(opened);
  check("a new tab: the window's toolbar follows it", opened.toolbars.length === 1 && opened.toolbars[0].tabId === opened.id && opened.active === opened.id, JSON.stringify(opened.toolbars));
  const closed = await ac(`${S} S().closeTab(${JSON.stringify(opened.id)}); return wt.frames(6).then(() => wt.state());`);
  await nativeState(closed);
  check("closing it: the toolbar shows the tab shown after it", closed.toolbars.length === 1 && closed.toolbars[0].tabId === closed.active && closed.active !== opened.id, JSON.stringify(closed));

  const split = await ac(`${S} S().createSplit(["a", "b"]); S().activate("a"); return wt.frames(6).then(() => wt.state());`);
  await nativeState(split);
  const paneBars = split.auto.filter((t) => t.pane).map((t) => t.tabId).sort();
  check("a split: each pane has its own toolbar, the window has none", split.auto.every((t) => t.pane) && paneBars.join() === "a,b", JSON.stringify(split.auto));
  const unsplit = await ac(`${S} for (const id of Object.keys(S().splits)) S().separateSplit(id); S().activate("d"); return wt.frames(6).then(() => wt.state());`);
  await nativeState(unsplit);
  check("out of the split: back to one window toolbar", unsplit.auto.length === 1 && !unsplit.auto[0].pane && unsplit.auto[0].tabId === "d", JSON.stringify(unsplit.auto));
} catch (e) {
  check("run", false, e.message);
} finally {
  await instance.quit();
}
const failed = results.filter((r) => !r).length;
console.log(failed ? `${failed} of ${results.length} checks failed` : `all ${results.length} checks passed`);
process.exit(failed ? 1 : 0);

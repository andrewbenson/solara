import { execFileSync, spawnSync } from "node:child_process";
import { sidebarSession, assertSidebarPosition, assertSidebarTrafficLights } from "./sidebar-position-test.mjs";
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
const page = (name, color) => `data:text/html,${encodeURIComponent(`<title>${name}</title><meta name="theme-color" content="${color}"><p>${name}</p>`)}`;
const tab = (id, url) => ({ id, url, title: id, favicon: null, pinned: false, muted: false, zoom: 1, customTitle: null, customIcon: null, pinnedUrl: null, navigation: null, openerId: null, createdAt: Date.now(), lastActiveAt: Date.now() });
const pages = { a: page("Tab-a", "#C0392B"), b: page("Tab-b", "#2471A3"), c: "https://example.com/c", d: "https://example.org/d" };
const ids = Object.keys(pages);
const fixture = sidebarSession({
    version: 2,
    profiles: { default: { id: "default", name: "Personal", color: "plum", icon: null, createdAt: 0 } },
    profileOrder: ["default"],
    orphanedProfileData: [],
    settings: { searchSuggestions: false, warnBeforeClosingLastTab: false, warnBeforeClosingWindow: false, extendWebsiteColor: true, sidebarIconsOnly: false, hideToolbarWhileScrolling: false },
    windows: [{ id: "w1", profileId: "default", incognito: false, tabIds: ids, activeTabIds: { default: "a" }, sidebarOpen: true, frame: [100, 100, 1200, 800], createdAt: 0 }],
    windowOrder: ["w1"],
    focusedWindowId: "w1",
    tabs: ids.map((id) => ({ ...tab(id, pages[id]), windowId: "w1", profileId: "default" })),
    groups: [],
    splits: [],
    closedTabs: [],
    closedWindows: [],
});
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
  let matched;
  let latest;
  let native;
  try {
    await untilSnapshot("toolbar tab ids, addresses and native host state", async (snapshot) => {
      native = snapshot;
      latest = await ac("return wt.state();");
      const window = snapshot.windows[0];
      if (!window || latest.active !== state.active || window.selectedTabId !== latest.active ||
        JSON.stringify(latest.tabIds) !== JSON.stringify(state.tabIds) || JSON.stringify(window.tabIds) !== JSON.stringify(latest.tabIds)) return false;
      if (latest.tabIds.some((id) => snapshot.tabs.find((tab) => tab.id === id)?.url !==
        snapshotURL(latest.tabUrls[id]))) return false;
      if (JSON.stringify(sortedBars(window.toolbarHosts)) !== JSON.stringify(sortedBars(latest.nativeToolbars))) return false;
      matched = latest;
      return true;
    });
  } catch (error) {
    try { writeFileSync(join(out, "toolbar-state-failure.json"), JSON.stringify({ captured: state, latest, native }, null, 2)); }
    catch (evidenceError) { console.error(`toolbar state evidence write failed: ${evidenceError.message}`); }
    throw error;
  }
  return { ...state, ...matched };
};
const results = [];
const check = (name, ok, detail = "") => {
  results.push(ok);
  console.log(`${ok ? "ok  " : "FAIL"} ${name}${detail ? `  (${detail})` : ""}`);
};
async function nativeChecks() {
  const readShell = () => ac('return globalThis.expo.modules.SolaraWindowShell.describe("w1").then(JSON.parse);');
  const waitShell = async (name, accept = () => true) => {
    const end = Date.now() + 15000;
    let last;
    while (Date.now() < end) {
      if (!instance.alive) throw new Error(`${name}: instance exited`);
      last = await readShell();
      if (last?.layout?.current && accept(last.layout)) return last;
      await sleep(100);
    }
    throw new Error(`${name}: native layout never matched (${JSON.stringify(last)})`);
  };
  const snapshot = async (name, shownIds, selected) => {
    const shell = await waitShell(name, (layout) => layout.selectedTabId === selected && shownIds.every((id) => layout.panes[id]));
    const snap = await untilSnapshot(name, (value) => {
      const window = value.windows[0];
      return window?.selectedTabId === selected && shownIds.every((id) => window.toolbarStates?.[id]?.hidden === false && window.toolbarHosts?.some((bar) => bar.tabId === id));
    }, 15000);
    const state = await ac('const s=ac.store.getState();return {urls:Object.fromEntries(s.windows.w1.tabIds.map(id=>[id,s.tabs[id]?.url])),autoHide:s.settings.hideToolbarWhileScrolling};');
    const window = snap.windows[0];
    for (const id of shownIds) {
      const bar = window.toolbarHosts.find((bar) => bar.tabId === id);
      check(`${name}: ${id} is a mounted native toolbar`, !!bar && window.toolbarStates[id].tabId === id && window.toolbarStates[id].hidden === false);
      const expected = state.urls[id]?.startsWith("data:") ? "data:" : state.urls[id] || null;
      check(`${name}: ${id} uses the current page address`, snap.tabs.find((tab) => tab.id === id)?.url === expected && (!/^https?:/.test(state.urls[id]) || bar.urlHost === new URL(state.urls[id]).hostname), JSON.stringify({ url: expected, host: bar.urlHost }));
    }
    check(`${name}: native page endpoints agree`, shell.layout.maxError <= 0.5, JSON.stringify(shell.layout.errors));
    return { shell, snap, window, state };
  };
  const activate = async (id) => {
    await ac(`ac.store.getState().activate(${JSON.stringify(id)});return true;`);
    await waitShell(`activate ${id}`, (layout) => layout.selectedTabId === id);
    if (id === "a" || id === "b") {
      await ac(`const id=${JSON.stringify(id)},s=ac.store.getState(),tab=s.tabs[id],facts=ac.nativePages.facts(id);if(!facts)return false;ac.nativePages.report(id,{type:"navigation",generation:facts.generation,url:tab.url,title:tab.title,isLoading:false,canGoBack:false,canGoForward:false,themeColor:id==="a"?"#C0392B":"#2471A3",eventSeq:facts.newestEventSeq+1});return true;`);
    }
  };
  for (const enabled of [true, false]) {
    await ac(`ac.store.getState().updateSettings({hideToolbarWhileScrolling:${enabled}});return true;`);
    for (const id of ["a", "b", "c", "d", "a"]) {
      await activate(id);
      const current = await snapshot(`${enabled ? "auto-hide" : "always shown"}: switch ${id}`, [id], id);
      check(`native switch ${id}: the single toolbar follows selection`, current.window.toolbarHosts.length === 1 && Object.keys(current.shell.layout.toolbarModes).length === 1);
      check(`native switch ${id}: the selected toolbar is shown`, current.shell.layout.toolbarModes[id] === "shown");
      const bar = current.window.toolbarHosts.find((bar) => bar.tabId === id);
      if (!enabled && ["a", "b"].includes(id)) check(`native switch ${id}: the site color reaches the toolbar`, bar.background === (id === "a" ? "#C0392B" : "#2471A3"), JSON.stringify(bar));
    }
  }
  await activate("a");
  const initial = await snapshot("native toolbar before style updates", ["a"], "a");
  const identity = initial.window.toolbarHosts.find((bar) => bar.tabId === "a").identity;
  for (const appearance of ["light", "dark"]) {
    for (const rail of [true, false]) {
      await ac(`ac.store.getState().updateSettings({appearance:${JSON.stringify(appearance)},hideToolbarWhileScrolling:false,sidebarIconsOnly:${rail}});return true;`);
      await waitShell(`${appearance} sidebar motion`);
      await sleep(500);
      const current = await snapshot(`${appearance}: ${rail ? "rail" : "full sidebar"}`, ["a"], "a");
      const bar = current.window.toolbarHosts.find((bar) => bar.tabId === "a");
      check(`${appearance}: native ${rail ? "rail" : "full sidebar"} surface colors`, !bar.bare && bar.windowToolbar === true && bar.hairline === !rail && (rail ? bar.background === null && bar.stripes === null : bar.background === "#C0392B"), JSON.stringify(bar));
      check(`${appearance}: native style changes keep the toolbar view`, typeof identity === "string" && bar.identity === identity, String(bar.identity));
      const path = join(out, `native-${appearance}-${rail ? "rail" : "full"}.png`);
      check(`${appearance}: native sidebar toolbar snapshot`, await ac(`return ac.shell.devSnapshotWindow("w1",${JSON.stringify(path)});`), path);
    }
  }
  await ac('ac.store.getState().updateSettings({hideToolbarWhileScrolling:true});return true;');
  await activate("c");
  await snapshot("native c ready for scroll", ["c"], "c");
  const reported = await ac('return globalThis.expo.modules.SolaraTabPool.devPageEvent("c","onPageMessage",{kind:"scroll",data:{state:"down"}});');
  check("native current page registration accepts scrolling", reported === true);
  const collapsed = await waitShell("native scrolling collapses", (layout) => layout.toolbarModes.c === "collapsed" && Math.abs(layout.presentationFacts.c.top - 20) <= 0.5);
  check("native scrolling collapses the shown toolbar", collapsed.layout.toolbarModes.c === "collapsed");
  const stripHost = () => ac('return expo.modules.SolaraAutoHide.devStripHost("w1","c");');
  check("collapsed strip shows the original host", await stripHost() === "example.com");
  await ac(`
    const module = expo.modules.SolaraAutoHide;
    globalThis.originalAutoHideStyle = module.setStyle;
    const suppress = () => Promise.resolve();
    module.setStyle = suppress;
    if (module.setStyle !== suppress) throw new Error("could not suppress JS auto-hide styling");
    return true;
  `);
  try {
    const url = "https://example.net/c";
    const report = await ac(`
      const state = ac.store.getState();
      const facts = ac.nativePages.facts("c");
      if (!facts) throw new Error("missing native page facts");
      return ac.nativePages.report("c", { type:"navigation", generation:facts.generation, eventSeq:facts.newestEventSeq+1,
        url:${JSON.stringify(url)}, title:state.tabs.c.title, themeColor:state.live.c?.themeColor,
        isLoading:false, canGoBack:false, canGoForward:false });
    `);
    if (!report || report.error) throw new Error(`native navigation report failed: ${JSON.stringify(report)}`);
    await untilSnapshot("navigation committed with the new collapsed strip host", async (value) =>
      value.tabs.some((tab) => tab.id === "c" && tab.url === url) && await stripHost() === "example.net");
    await waitShell("strip stayed collapsed after the navigation report", (layout) => layout.toolbarModes.c === "collapsed");
    check("collapsed strip updates after navigation with JS styling suppressed", true);
  } finally {
    await ac('expo.modules.SolaraAutoHide.setStyle = globalThis.originalAutoHideStyle; delete globalThis.originalAutoHideStyle; return true;');
  }
  await activate("d");
  check("native next tab has a shown toolbar", (await snapshot("native next tab", ["d"], "d")).shell.layout.toolbarModes.d === "shown");
  await activate("c");
  check("native returning to a scrolled tab reveals its toolbar", (await snapshot("native returned tab", ["c"], "c")).shell.layout.toolbarModes.c === "shown");
  const opened = await ac('return ac.store.getState().newTab("w1");');
  await snapshot("native new tab", [opened], opened);
  await ac(`ac.store.getState().closeTab(${JSON.stringify(opened)});return true;`);
  await waitShell("native closed new tab", (layout) => layout.selectedTabId !== opened);
  const afterClose = await ac('const s=ac.store.getState();return s.windows.w1.activeTabIds.default;');
  await snapshot("native toolbar after close", [afterClose], afterClose);
  const split = await ac('const s=ac.store.getState();const id=s.createSplit(["a","b"]);s.activate("a");return id;');
  const paired = await snapshot("native split toolbars", ["a", "b"], "a");
  check("native split has exactly one toolbar for each pane", paired.window.toolbarHosts.map((bar) => bar.tabId).sort().join() === "a,b");
  await ac('return globalThis.expo.modules.SolaraTabPool.devPageEvent("b","onPageMessage",{kind:"scroll",data:{state:"down"}});');
  const splitModes = await waitShell("native split independent scroll", (layout) => layout.toolbarModes.a === "shown" && layout.toolbarModes.b === "collapsed");
  check("native split toolbars have independent modes", splitModes.layout.toolbarModes.a === "shown" && splitModes.layout.toolbarModes.b === "collapsed");
  await ac(`ac.store.getState().separateSplit(${JSON.stringify(split)});ac.store.getState().activate("d");return true;`);
  const unpaired = await snapshot("native split ended", ["d"], "d");
  check("native leaving split restores one selected toolbar", unpaired.window.toolbarHosts.length === 1);
  const mounts = await ac('return Object.fromEntries(["Toolbar","AutoHideToolbar","LegacyContentCard","TabPane","WindowToolbar"].map(name=>[name,acPerf.findFibers(name,50).length]));');
  check("native toolbar checks use no React toolbar layout hosts", Object.values(mounts).every((count) => count === 0), JSON.stringify(mounts));
}

try {
  let ready = false;
  for (let i = 0; i < 60 && !ready; i++) ready = await ac("return !!ac.store.getState().windows.w1;", 2000).then((v) => v, () => false);
  if (!ready) throw new Error("the dev harness never answered");
  await assertSidebarPosition(instance);
  const nativeLayout = await ac('return globalThis.expo.modules.SolaraWindowShell.describe("w1").then(value=>JSON.parse(value)?.nativeLayout===true);');
  if (nativeLayout) await nativeChecks();
  else {
  await ac(`
    globalThis.wt = {
      frames: (n) => new Promise((r) => { let k = n || 3; const step = () => (k-- > 0 ? requestAnimationFrame(step) : r()); step(); }),
      fibers: (name) => acPerf.findFibers(name, 500).filter((f) => f.memoizedProps),
      inPane: (f) => { for (let p = f.return; p; p = p.return) if (p.type?.type?.name === "TabPane" || p.type?.name === "TabPane" || p.elementType?.type?.name === "TabPane") return p.memoizedProps.tabId; return null; },
      state: () => {
        const toolbars = wt.fibers("Toolbar").map((f) => ({ tabId: f.memoizedProps.tabId, bare: !!f.memoizedProps.bare, windowToolbar: !!f.memoizedProps.windowToolbar, pane: wt.inPane(f) }));
        const auto = wt.fibers("AutoHideToolbar").map((f) => ({ tabId: f.memoizedProps.tabId, mode: f.memoizedProps.mode, pane: wt.inPane(f) }));
        const backdrops = [...wt.fibers("AutoHideBackdrop"), ...wt.fibers("ToolbarBackdrop"), ...wt.fibers("NativeAutoHide")].map((f) => ({ tabId: f.memoizedProps.tabId, pane: wt.inPane(f) }));
        const native = JSON.parse(expo.modules.SolaraToolbar.devToolbarStates("w1"));
        const hosts = [...wt.fibers("UrlField").map((f) => f.memoizedProps.tab?.url), ...native.filter((n) => n.url?.host).map((n) => ac.store.getState().tabs[n.tabId]?.url)];
        const w = ac.store.getState().windows.w1;
        return { active: w.activeTabIds[w.profileId], hideToolbarWhileScrolling: ac.store.getState().settings.hideToolbarWhileScrolling, toolbars, auto, backdrops, hosts,
          tabIds: [...w.tabIds], tabUrls: Object.fromEntries(w.tabIds.map((id) => [id, ac.store.getState().tabs[id]?.url])),
          nativeToolbars: native.map((n) => ({ tabId: n.tabId, bare: !!n.bare, windowToolbar: !!n.windowToolbar, background: n.palette.background ?? null, hairline: n.hairline, stripes: n.stripes ?? null, urlHost: n.url?.host ?? null })) };
      },
      until: (test, ms) => new Promise((r) => { const end = Date.now() + (ms || 15000); const poll = () => (test() ? r(true) : Date.now() > end ? r(false) : setTimeout(poll, 50)); poll(); }),
    };
    return true;`);
  const S = "const S = () => ac.store.getState();";
  const switchTo = async (id) => {
    const state = await ac(`${S} acPerf.reset(); S().activate(${JSON.stringify(id)}); return wt.frames(4).then(() => ({ ...wt.state(), mounted: acPerf.read().mounts.Toolbar ?? 0 }));`);
    const current = await nativeState(state);
    if (id === "a" || id === "b") {
      return ac(`${S} const id = ${JSON.stringify(id)}, tab = S().tabs[id], facts = ac.nativePages.facts(id); ac.nativePages.report(id, { type: "navigation", generation: facts.generation, url: tab.url, title: tab.title, isLoading: false, canGoBack: false, canGoForward: false, themeColor: id === "a" ? "#C0392B" : "#2471A3", eventSeq: facts.newestEventSeq + 1 }); return wt.frames(4).then(() => ({ ...wt.state(), mounted: ${state.mounted} }));`);
    }
    return current;
  };

  for (const mode of ["auto-hide", "always shown"]) {
    const autoHide = mode === "auto-hide";
    await ac(`${S} S().updateSettings({ hideToolbarWhileScrolling: ${autoHide} }); return wt.frames(4).then(() => true);`);
    await switchTo("a");
    for (const id of ["b", "c", "d", "a"]) {
      const st = await switchTo(id);
      const windowBars = st.toolbars.filter((t) => !t.pane);
      const nativeStatic = mode === "always shown" && windowBars[0]?.windowToolbar === true;
      const surface = nativeStatic ? !windowBars[0].bare && st.nativeToolbars.some((n) => n.tabId === id && n.windowToolbar && !n.bare && n.hairline === true && (id !== "a" && id !== "b" || n.background === (id === "a" ? "#C0392B" : "#2471A3"))) : windowBars[0]?.bare;
      const selectedMode = st.hideToolbarWhileScrolling === autoHide && (autoHide ? st.auto.length === 1 && st.auto[0].tabId === id && !st.auto[0].pane && st.auto[0].mode === "shown" : st.auto.length === 0);
      check(`${mode}: switching to ${id}, the window's one toolbar shows ${id}`, selectedMode && windowBars.length === 1 && windowBars[0].tabId === id && st.toolbars.length === 1 && surface, JSON.stringify({ hideToolbarWhileScrolling: st.hideToolbarWhileScrolling, auto: st.auto, toolbars: st.toolbars }));
      check(`${mode}: switching to ${id}, the toolbar is kept, not mounted again`, st.mounted === 0, `Toolbar mounts ${st.mounted}`);
      const url = st.tabUrls[id];
      check(`${mode}: switching to ${id}, the address field shows ${id}'s address`, st.hosts.length === 1 && st.hosts[0] === url, JSON.stringify({ hosts: st.hosts, expected: url }));
      const backdrop = autoHide ? st.backdrops.length === 1 && st.backdrops[0].tabId === id && st.backdrops[0].pane === id : st.backdrops.length === 0;
      check(`${mode}: switching to ${id}, the band belongs to ${id}'s toolbar`, backdrop, JSON.stringify(st.backdrops));
    }
  }
  for (const appearance of ["light", "dark"]) {
    await ac(`${S} S().updateSettings({ appearance: ${JSON.stringify(appearance)}, hideToolbarWhileScrolling: false }); return wt.frames(4).then(() => true);`);
    await switchTo("a");
    for (const rail of [true, false]) {
      await ac(`ac.runCommand({ command: "toggleSidebarIconsOnly", windowId: "w1" }); return wt.frames(8).then(() => new Promise((r) => setTimeout(r, 250))).then(() => true);`);
      const st = await switchTo("a");
      await assertSidebarTrafficLights(instance);
      const bar = st.nativeToolbars.find((n) => n.tabId === "a");
      check(`${appearance}: ${rail ? "rail" : "full sidebar"} switches the live native surface`, !!bar && !bar.bare && bar.windowToolbar && bar.hairline === !rail && (rail ? bar.background === null && bar.stripes === null : bar.background === "#C0392B"), JSON.stringify(bar));
      const path = join(out, `${appearance}-${rail ? "rail" : "full"}.png`);
      check(`${appearance}: ${rail ? "rail" : "full sidebar"} in-process snapshot`, await ac(`return ac.shell.devSnapshotWindow("w1", ${JSON.stringify(path)});`), path);
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
  }
} catch (e) {
  check("run", false, e.message);
} finally {
  await instance.quit();
}
const failed = results.filter((r) => !r).length;
console.log(failed ? `${failed} of ${results.length} checks failed` : `all ${results.length} checks passed`);
process.exit(failed ? 1 : 0);

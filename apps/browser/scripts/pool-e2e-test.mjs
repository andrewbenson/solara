import { mkdtempSync, rmSync } from "node:fs";
import { createServer } from "node:http";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { launch, reporter, session, sleep } from "../../../scripts/lib/instance.mjs";
import { poolPage } from "../../../scripts/lib/fixture-html.mjs";

const args = process.argv.slice(2);
const appArg = args.find((a) => !a.startsWith("--"));
if (!appArg || resolve(appArg).startsWith("/Applications/")) {
  console.error(`usage: node pool-e2e-test.mjs <Debug Solara.app under apps/browser/build-*> [--keep-data]

The page pool end to end (docs/native/page-contract.md › Checks), in a hidden instance under the native shell with
pane roots and the pool on (SOLARA_NATIVE_SHELL=1 SOLARA_SHELL_PANES=1 SOLARA_NATIVE_PAGES_POOL=1): the pool serves the
window's pages and RN mounts no TabWebView; the tab's handle reaches the page (evaluate, find and its match count,
zoom in and back, load and go back); the page's events reach the store (title, favicon, load progress partway and
then done); a page's notification reaches native diagnostics and its native response fires Chromium's page onclick
while another tab is active; a peek opens on its own pooled page and Open as Tab promotes that page into the window;
in a split, a click in the unfocused pane focuses it and a pane's close button closes its tab; a tab moved to another
profile, and back, gets a new page each time in the right profile (cookies prove it); and an engine change makes a new
page whose ready reaches the store, never one revived from an armed WebKit transfer, and that keeps keyboard focus
when the old page had it; and a switch to a profile showing a New Tab draws no page from the previous profile, WebKit or
Chromium, while switching back draws its page again. A build whose pool doesn't serve pages fails every check.`);
  process.exit(2);
}
const keep = args.includes("--keep-data");
const scratch = mkdtempSync(join(tmpdir(), "ac-pool-e2e-"));
const rep = reporter(join(scratch, "pool-e2e-test.log"), { name: "pool-e2e-test" });

const ICON = Buffer.from("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8DwHwAFBQIAX8jx0gAAAABJRU5ErkJggg==", "base64");
const cookies = {};
const server = createServer((req, res) => {
  const path = req.url.split("?")[0].slice(1);
  cookies[path] = req.headers.cookie ?? "";
  if (path === "icon.png") {
    res.writeHead(200, { "content-type": "image/png" });
    return res.end(ICON);
  }
  if (path === "slow.png") return setTimeout(() => (res.writeHead(200, { "content-type": "image/png" }), res.end(ICON)), 2500);
  res.writeHead(200, { "content-type": "text/html", ...(path === "set" ? { "set-cookie": "who=A; Path=/; Max-Age=3600" } : {}) });
  const slow = path === "slow" ? `<img src="/slow.png?${Date.now()}">` : "";
  res.end(poolPage(path, slow));
});
await new Promise((r) => server.listen(0, "127.0.0.1", r));
const origin = `http://127.0.0.1:${server.address().port}`;
const url = (n) => `${origin}/${n}`;
const fixture = session({
  windows: [{ id: "w1", frame: [80, 80, 1280, 800], activeTabIds: { default: "a" } }],
  tabs: [{ id: "a", url: url("one"), title: "ONE" }, { id: "b", url: url("two"), title: "TWO" }],
  settings: { warnBeforeClosingLastTab: false, warnBeforeClosingWindow: false },
});

const HELPERS = `
const S = () => ac.store.getState();
const W = globalThis.expo.modules.SolaraWindowShell;
const page = (id) => ac.webviews.get(id);
const active = () => S().windows.w1.activeTabIds.default;
const ev = (id, expr) => page(id).evaluate("post('result', JSON.stringify(" + expr + "))");
const go = (id, url, extra = {}) => S().updateTab(id, { ...extra, navigation: { url, seq: (S().tabs[id].navigation?.seq ?? 0) + 1, fresh: true } });
const live = (id) => globalThis.expo.modules.SolaraTabPool.livePages().then((pages) => pages.find((p) => p.tabId === id));
const mapped = (id) => Object.entries(ac.pageState.getState().browsers).filter(([, tab]) => tab === id).map(([browser]) => Number(browser));
`;
let app = null;
const run = (body, timeout = 20000) => app.eval(`${HELPERS}\n${body}`, { timeout });
const until = async (what, body, ms = 10000) => {
  const end = Date.now() + ms;
  let last;
  while (Date.now() < end) {
    last = await run(body).catch((e) => ({ error: String(e.message ?? e) }));
    if (last && !last.error) return last;
    await sleep(100);
  }
  throw new Error(`${what}: never true (last ${JSON.stringify(last)})`);
};
const json = JSON.stringify;
const untilSnapshot = async (what, accept, ms = 5000) => {
  const end = Date.now() + ms;
  let last;
  while (Date.now() < end) {
    last = await app.snapshot({ windowId: "w1" }).catch((error) => ({ error: error.message }));
    if (!last.error && last.consistent && accept(last)) return last;
    await sleep(100);
  }
  throw new Error(`${what}: native snapshot never matched (${JSON.stringify(last)})`);
};

try {
  app = await launch(resolve(appArg), {
    data: join(scratch, "data"), fresh: true, session: fixture, onboarded: true, probe: true,
    env: { SOLARA_NATIVE_SHELL: "1", SOLARA_SHELL_PANES: "1", SOLARA_NATIVE_PAGES_POOL: "1", SOLARA_TAB_POOL: "1" },
    ready: "return !!ac.store.getState().windows.w1 && !!globalThis.acPerf",
  });
  await until("page ONE", `return S().tabs.a.title === "ONE" || null;`, 15000);

  await rep.check("the pool serves the window's pages and RN mounts no TabWebView", async () => {
    const info = await run(`return W.devHitCost("w1", 600, 400).then((h) => ({ available: !!globalThis.expo.modules.SolaraTabPool?.available?.(), handle: !!page("a"), rn: acPerf.findFibers("TabWebView", 10).length, slot: h.slot }));`);
    if (!info.available) throw new Error("SolaraTabPool isn't available");
    if (!info.handle) throw new Error("no handle registered for tab a");
    if (info.rn) throw new Error(`${info.rn} TabWebView still mounted`);
    return info;
  });

  await rep.check("evaluate reaches the page", async () => {
    const title = await run(`return ev("a", "document.title");`);
    if (title !== "ONE") throw new Error(`document.title is ${json(title)}`);
    return title;
  });

  await rep.check("find reaches the page and its match count reaches the store", async () => {
    await run(`S().setFind("a", { open: true, count: null, active: 0 }); return page("a").find("needle", true, false).then(() => true);`);
    const find = await until("two matches", `const f = S().find.a; return f && f.count === 2 ? f : null;`);
    await run(`S().setFind("a", { open: false, count: null, active: 0 }); return page("a").stopFinding(true).then(() => true);`);
    return find;
  });

  await rep.check("zoom in reaches the page and its zoom reaches the store; reset brings it back", async () => {
    await run(`return page("a").zoomStep(1).then(() => true);`);
    const zoomed = await until("zoomed in", `const z = S().tabs.a.zoom; return z && z > 1 ? z : null;`);
    const nativeZoomed = await untilSnapshot("native zoom", (state) => state.tabs.some((tab) => tab.id === "a" && Math.abs(tab.zoom - zoomed) <= 0.001));
    if (Math.abs(nativeZoomed.tabs.find((tab) => tab.id === "a").zoom - zoomed) > 0.001) throw new Error("native zoom differs from JS");
    await run(`return page("a").zoomStep(0).then(() => true);`);
    const reset = await until("zoom reset", `const z = S().tabs.a.zoom; return !z || z === 1 ? { z: z ?? 1 } : null;`);
    await untilSnapshot("native zoom reset", (state) => state.tabs.some((tab) => tab.id === "a" && Math.abs(tab.zoom - reset.z) <= 0.001));
    return { zoomed, reset: reset.z };
  });

  await rep.check("loadUrl and goBack reach the page; title and url come back through the store", async () => {
    await run(`return page("a").loadUrl(${json(url("three"))}).then(() => true);`);
    await until("THREE", `return S().tabs.a.title === "THREE" && S().live.a?.canGoBack ? true : null;`);
    await run(`return page("a").goBack().then(() => true);`);
    const landed = await until("back to ONE", `const t = S().tabs.a; return t.title === "ONE" && t.url === ${json(url("one"))} ? t.url : null;`);
    await untilSnapshot("native back navigation", (state) => state.tabs.some((tab) => tab.id === "a" && tab.title === "ONE" && tab.url === landed));
    return landed;
  });

  await rep.check("the favicon event reaches the store", async () =>
    until("favicon", `const t = S().tabs.a; return t.favicon ? String(t.favicon).slice(0, 60) : null;`));

  await rep.check("load progress reaches the store, partway and then done", async () => {
    await run(`globalThis.__poolProgress = []; globalThis.__poolProgressStop = ac.pageProgress.watchPageProgress("a", () => __poolProgress.push(ac.pageProgress.pageProgressOf("a"))); return page("a").loadUrl(${json(url("slow"))}).then(() => true);`);
    await until("load finished", `return S().tabs.a.title === "SLOW" && !S().live.a?.isLoading ? true : null;`, 10000);
    await sleep(300);
    const seen = await run(`__poolProgressStop(); return __poolProgress;`);
    if (!seen.some((p) => p > 0 && p < 1)) throw new Error(`no partial progress: ${json(seen)}`);
    if (![0, 1].includes(seen.at(-1))) throw new Error(`progress ended at ${seen.at(-1)}: ${json(seen)}`);
    return seen.slice(0, 12);
  });

  await rep.check("a native notification response reaches Chromium's pooled document listener", async () => {
    await run(`return globalThis.expo.modules.SolaraCEF.setSiteSetting("", ${json(origin)}, "notifications", "allow").then(() => true);`);
    await run(`return ev("a", "(() => { window.__poolNotification = new Notification('Ping', { body: 'pool', tag: 'pool' }); window.__poolNotification.onclick = () => { document.title = 'CLICKED'; }; return true; })()");`);
    const shown = await until("the native notification is delivered and acknowledged", `return globalThis.expo.modules.SolaraCEF.notificationDebugSnapshot().then((value) => {
      if (!value.hub?.diagnosticsComplete || !value.hub.delivered) return null;
      const native = value.hub.delivered.find((row) => row.title === "Ping" && row.body === "pool");
      const route = value.routes?.find((row) => row.nativeID === native?.nativeID && row.accepted && !row.withdrawn && new URL(row.origin).origin === ${json(origin)});
      const posted = value.hub.posts?.find((row) => row.nativeID === route?.nativeID && row.status === "accepted");
      const ack = value.hub.acks?.find((row) => row.nativeID === route?.nativeID && row.receipt === posted?.receipt && row.engineAccepted === true);
      return route && posted && ack ? { nativeID: route.nativeID, token: route.token, generation: route.generation } : null;
    });`);
    await run(`S().activate("b"); return true;`);
    await until("b active", `return active() === "b" || null;`);
    const response = await run(`return globalThis.expo.modules.SolaraApp.notificationDebugRespond(${json(shown.nativeID)}, "com.apple.UNNotificationDefaultActionIdentifier");`);
    if (response?.accepted !== true) throw new Error(`native response rejected: ${json(response)}`);
    await until("Chromium dispatched the document onclick", `return ev("a", "document.title").then((t) => t === "CLICKED" || null);`);
    await run(`S().activate("a"); return ev("a", "(() => { window.__poolNotification.close(); return true; })()");`);
    return shown;
  });

  await rep.check("a peek opens on its own pooled page and Open as Tab promotes it into the window", async () => {
    const peekId = await run(`return S().openPeek("a", ${json(url("peeked"))});`);
    await until("the peek's page loads", `const p = S().peeks.w1; return p && p.tabId === ${json(peekId)} && S().tabs[p.tabId]?.title === "PEEKED" ? true : null;`);
    const inPeek = await run(`return ev(${json(peekId)}, "document.title");`);
    if (inPeek !== "PEEKED") throw new Error(`the peek's handle reads ${json(inPeek)}`);
    await run(`ac.peek.openPeekAsTab("w1"); return true;`);
    await until("promoted", `return !S().peeks.w1 && S().windows.w1.tabIds.includes(${json(peekId)}) && active() === ${json(peekId)} ? true : null;`, 5000);
    const after = await until("the promoted page still answers", `return ev(${json(peekId)}, "document.title").then((t) => t === "PEEKED" ? t : null);`);
    await run(`S().activate("a"); return true;`);
    return { peekId, after };
  });

  await rep.check("a click in the unfocused split pane focuses it", async () => {
    await run(`S().createSplit(["a", "b"]); S().activate("a"); return true;`);
    const panes = await until("two panes placed", `return W.describe("w1").then(JSON.parse).then((d) => d.split && d.split.panes && d.split.panes.a && d.split.panes.b ? { card: d.card, panes: d.split.panes } : null);`);
    await sleep(500);
    const [cx, cy] = panes.card;
    const [bx, by, bw, bh] = panes.panes.b;
    const x = Math.round(cx + bx + bw / 2), y = Math.round(cy + by + bh * 0.6);
    const click = await run(`return ac.shell.devClick("w1", { x: ${x}, y: ${y}, wait: 250 });`);
    if (!/RenderWidgetHostViewCocoa|WebContentsViewCocoa/.test(String(click.hit))) throw new Error(`the click at ${x},${y} landed on ${click.hit}`);
    await until("b focused", `return active() === "b" || null;`, 3000);
    const native = await untilSnapshot("native split focus", (state) => state.windows[0]?.selectedTabId === "b" && ["a", "b"].every((id) => state.windows[0]?.split?.leaves?.[id]));
    if (native.windows[0].selectedTabId !== "b") throw new Error(`native selected ${native.windows[0].selectedTabId}`);
    return { at: [x, y], hit: click.hit };
  });

  await rep.check("a split pane's close button closes its tab and leaves the other one alone", async () => {
    const panes = await until("two panes placed", `return W.describe("w1").then(JSON.parse).then((d) => d.split && d.split.panes && d.split.panes.a && d.split.panes.b ? { card: d.card, panes: d.split.panes } : null);`);
    const [cx, cy] = panes.card;
    const [ax, ay, aw] = panes.panes.a;
    const x = Math.round(cx + ax + aw - 8 - 15), y = Math.round(cy + ay + 20);
    const click = await run(`return ac.shell.devClick("w1", { x: ${x}, y: ${y}, wait: 250 });`);
    if (click.hit !== "ToolbarButtonView") throw new Error(`the click at ${x},${y} landed on ${click.hit}`);
    await until("a closed", `return !S().tabs.a && !Object.keys(S().splits).length && S().windows.w1.tabIds.includes("b") || null;`, 3000);
    return { at: [x, y], hit: click.hit };
  });

  const loaded = (path, ms = 8000) => until(`${path} loaded`, `return live("b").then((p) => p?.navigation?.url === ${json(url(path))} && !p.navigation.isLoading ? { browser: p.ready?.browserId, engine: p.engine, back: p.navigation.canGoBack } : null);`, ms);
  const cookie = async (path) => {
    const end = Date.now() + 5000;
    while (!(path in cookies) && Date.now() < end) await sleep(50);
    return cookies[path];
  };

  await rep.check("a tab moved to another profile gets a new page in that profile, and moving it back makes another new page", async () => {
    await run(`S().activate("b"); go("b", ${json(url("set"))}); return true;`);
    await loaded("set");
    await run(`go("b", ${json(url("home"))}); return true;`);
    const home = await loaded("home");
    if ((await cookie("home")) !== "who=A") throw new Error(`the home profile sent ${json(cookies.home)}`);
    await run(`const before = Object.keys(S().profiles); S().createProfile({ name: "Work" }); globalThis.__work = Object.keys(S().profiles).find((k) => !before.includes(k)); S().moveTabToProfile("b", globalThis.__work); return true;`);
    await until("a new page for b", `return live("b").then((p) => p?.ready && p.ready.browserId !== ${home.browser} ? true : null);`);
    await run(`go("b", ${json(url("work"))}); return true;`);
    const work = await loaded("work");
    if ((await cookie("work")) !== "") throw new Error(`the moved tab sent the home profile's cookie ${json(cookies.work)}`);
    await run(`S().moveTabToProfile("b", "default"); return true;`);
    await until("another new page for b", `return live("b").then((p) => p?.ready && ![${home.browser}, ${work.browser}].includes(p.ready.browserId) ? true : null);`);
    await run(`go("b", ${json(url("back"))}); return true;`);
    const back = await loaded("back");
    if ((await cookie("back")) !== "who=A") throw new Error(`back home the tab sent ${json(cookies.back)}`);
    return { home: home.browser, work: work.browser, back: back.browser };
  });

  await rep.check("an engine change makes a new page whose ready reaches the store", async () => {
    await run(`go("b", ${json(url("w1"))}, { engine: "webkit" }); return true;`);
    const w1 = await loaded("w1");
    if (w1.engine !== "webkit") throw new Error(`engine ${w1.engine}`);
    return until("ready mapped", `return live("b").then((p) => mapped("b").includes(p?.ready?.browserId) ? mapped("b") : null);`, 3000);
  });

  await rep.check("a transfer armed on a WebKit page doesn't bring it back after a round trip through Chromium", async () => {
    await run(`go("b", ${json(url("w2"))}); return true;`);
    await loaded("w2");
    await run(`globalThis.expo.modules.SolaraWebKit.prepareTransfer("b"); go("b", ${json(url("c1"))}, { engine: "chromium" }); return true;`);
    const c1 = await loaded("c1");
    if (c1.engine !== "chromium") throw new Error(`engine ${c1.engine}`);
    await run(`go("b", ${json(url("w3"))}, { engine: "webkit" }); return true;`);
    const w3 = await loaded("w3");
    if (w3.back) throw new Error("the WebKit page came back with its old history");
    return { c1: c1.browser, w3: w3.browser };
  });

  await rep.check("a page that had keyboard focus hands it to the page that replaces it", async () => {
    await run(`go("b", ${json(url("f1"))}, { engine: "chromium" }); return true;`);
    await loaded("f1");
    const card = await run(`return W.describe("w1").then(JSON.parse).then((d) => d.card);`);
    const click = await run(`return ac.shell.devClick("w1", { x: ${card[0] + 300}, y: ${card[1] + 300}, wait: 300 });`);
    if (click.firstResponderAfter !== "RenderWidgetHostViewCocoa") throw new Error(`the click left focus on ${click.firstResponderAfter}`);
    await run(`go("b", ${json(url("f2"))}, { engine: "webkit" }); return true;`);
    await loaded("f2");
    await run(`return page("b").evaluate("window.__keys = []; addEventListener('keydown', (e) => __keys.push(e.key)); post('result', 'ok')");`);
    await run(`return globalThis.expo.modules.SolaraApp.devPostKeys("w1", [{ key: "k", keyCode: 40, send: true }]).then(() => true);`);
    await sleep(300);
    const keys = await run(`return page("b").evaluate("post('result', JSON.stringify(__keys))");`);
    if (!String(keys).includes("k")) throw new Error(`the new page got ${json(keys)}`);
    return { keys };
  });

  const drawnPages = () => run(`
    const P = globalThis.expo.modules.SolaraPages;
    return globalThis.expo.modules.SolaraCEF.chromeWindows().then((all) => {
      const n = all.find((w) => w.hasRoot).window;
      const probes = ["WKWebView", "SolaraCoreWebView"].flatMap((kind) => [0, 1, 2, 3].map((i) => P.devViewFrame(n, kind + "#" + i)));
      return Promise.all(probes).then((found) => found.map(JSON.parse).filter((v) => v.found && v.alpha > 0).map((v) => v.class));
    });`);
  for (const engine of ["webkit", "chromium"]) {
    await rep.check(`a switch to a profile showing a New Tab draws no page from the previous profile (${engine})`, async () => {
      await run(`S().switchProfile("w1", "default"); S().activate("b"); go("b", ${json(url(`switch-${engine}`))}, { engine: ${json(engine)} }); return true;`);
      const before = await loaded(`switch-${engine}`);
      if (before.engine !== engine) throw new Error(`engine ${before.engine}`);
      const shown = await sleep(300).then(drawnPages);
      if (shown.length !== 1) throw new Error(`before the switch the card draws ${json(shown)}`);
      await run(`S().switchProfile("w1", globalThis.__work); const w = S().windows.w1; if (!w.activeTabIds[w.profileId]) S().newTab("w1", {}); return true;`);
      const target = await until("the Work window on a New Tab", `const w = S().windows.w1; const t = S().tabs[w.activeTabIds[w.profileId]]; return w.profileId === globalThis.__work && t && t.profileId === w.profileId && !t.navigation ? { tab: t.id, url: t.url } : null;`);
      await untilSnapshot("native Work profile", (state) => state.windows.some((w) => w.id === "w1" && w.profileId !== "default"));
      await sleep(500);
      const after = await drawnPages();
      if (after.length) throw new Error(`the New Tab shows ${json(after)} from the previous profile`);
      await run(`S().switchProfile("w1", "default"); return true;`);
      const back = await until("b drawn again", `return S().windows.w1.profileId === "default" || null;`).then(() => sleep(300)).then(drawnPages);
      if (back.length !== 1) throw new Error(`back on the home profile the card draws ${json(back)}`);
      return { engine, target, back };
    });
  }
} catch (e) {
  rep.record("run", { error: e });
} finally {
  await app?.quit().catch(() => {});
  server.close();
  if (!keep && rep.disposable) rmSync(scratch, { recursive: true, force: true });
}
const failed = rep.results.filter((r) => !r.ok);
console.log(`${rep.results.length - failed.length}/${rep.results.length} passed${failed.length ? `; log ${rep.logFile}` : ""}`);
process.exit(failed.length ? 1 : 0);

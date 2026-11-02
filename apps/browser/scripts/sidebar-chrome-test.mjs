import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { launch, reporter, session, sleep } from "../../../scripts/lib/instance.mjs";

const args = process.argv.slice(2);
const appArg = args.find((a) => !a.startsWith("--"));
if (!appArg) {
  console.error(`usage: node sidebar-chrome-test.mjs <Debug Solara.app> [--keep-data]

The native sidebar column's own chrome, with the window shell, native sidebar and top strip switches on:
the blank header drags the window and a double-click there does what the titlebar's does; the sidebar address bar sits
in the header's slot, survives toggling it out and back and a reload, and opens its dropdown; the header's and the
footer's downloads buttons open the downloads list; the resize handle drags the width live, keeps it on release and
resets it on a double-click; the footer's profile dots switch profiles; a drop on the header or the footer opens a tab,
and a tab dragged over the window lights the native drop glow; with top tabs the column and its chrome go away. A click
on a profile dot after every check makes sure the check left clicks working.`);
  process.exit(2);
}
const keep = args.includes("--keep-data");
const scratch = mkdtempSync(join(tmpdir(), "ac-sidebar-chrome-"));
const rep = reporter(join(scratch, "sidebar-chrome-test.log"), { name: "sidebar-chrome-test" });
const fixture = session({
  profiles: [{ id: "default", name: "Personal" }, { id: "work", name: "Work" }],
  windows: [{ id: "w1", frame: [80, 80, 1280, 800], activeTabIds: { default: "a" } }],
  tabs: [{ id: "a", url: "about:blank", title: "A" }, { id: "b", url: "about:blank", title: "B" }, { id: "c", url: "about:blank", title: "C" }],
  settings: { warnBeforeClosingLastTab: false, warnBeforeClosingWindow: false, addressBar: "sidebar" },
});
const HELPERS = `
const C = globalThis.expo.modules.SolaraCEF;
const H = globalThis.expo.modules.SolaraHosted;
const st = () => ac.store.getState();
const settle = (ms) => new Promise((r) => setTimeout(r, ms));
const win = () => C.chromeWindows().then((ws) => ws.find((w) => w.hasRoot).window);
const act = (a) => win().then((n) => C.devWindow(n, a));
const frame = () => win().then((n) => C.chromeWindows().then((ws) => ws.find((w) => w.window === n).frame));
const col = () => H.sidebarShell("w1").then((d) => JSON.parse(d));
const click = (x, y, n = 1) => act("mouse:down:" + x + "," + y + "," + n).then(() => settle(30)).then(() => act("mouse:up:" + x + "," + y + "," + n)).then(() => settle(60));
`;
const centre = (c, r) => [Math.round(c.frame[0] + r[0] + r[2] / 2), Math.round(c.frame[1] + r[1] + r[3] / 2)];
let inst = null;
const run = (body) => inst.eval(`${HELPERS}\n${body}`, { timeout: 30000 });
const untilSnapshot = async (what, accept, ms = 5000) => {
  const end = Date.now() + ms;
  let last;
  while (Date.now() < end) {
    last = await inst.snapshot({ windowId: "w1" }).catch((error) => ({ error: error.message }));
    if (!last.error && accept(last.windows.find((w) => w.id === "w1"), last)) return last;
    await sleep(100);
  }
  throw new Error(`${what}: native snapshot never matched (${JSON.stringify(last)})`);
};
const nearRect = (a, b) => a && b && a.length === b.length && a.every((v, i) => Math.abs(v - b[i]) <= 0.5);
const checkColumn = (what, column) => untilSnapshot(what, (window) => {
  const read = window?.sidebarShell;
  return read && nearRect(read.frame, column.frame) && read.chrome?.header === column.chrome?.header &&
    JSON.stringify(read.chrome?.dots?.map((dot) => dot.id)) === JSON.stringify(column.chrome?.dots?.map((dot) => dot.id));
});

const canary = async (after) => {
  const r = await run(`return col().then((c) => { const d = c.chrome.dots.find((d) => d.id === "work"); const x = Math.round(d.rect[0] + d.rect[2] / 2), y = Math.round(d.rect[1] + d.rect[3] / 2);
    return click(x, y).then(() => settle(1000)).then(() => st().windows.w1.profileId); });`).catch((e) => String(e));
  if (r === "work") await untilSnapshot("profile dot after " + after, (window) => window?.profileId === r);
  await run(`st().switchProfile("w1", "default"); return settle(1000);`);
  rep.record("canary after " + after, r === "work" ? { evidence: r } : { error: new Error(String(r)) });
};
try {
  inst = await launch(resolve(appArg), {
    data: join(scratch, "data"),
    fresh: true,
    session: fixture,
    onboarded: true,
    env: { SOLARA_NATIVE_SHELL: "1", SOLARA_NATIVE_SIDEBAR: "1", SOLARA_NATIVE_TOP_STRIP: "1" },
    ready: "return !!ac.store.getState().windows.w1",
  });
  await sleep(2500);
  const c0 = await run(`return col();`);
  if (!c0?.chrome) throw new Error(`no native chrome: ${JSON.stringify(c0)}`);
  await checkColumn("sidebar column at launch", c0);

  await canary("launch");
  await rep.check("(a) the blank header drags the window, and a double-click acts as the titlebar's", async () => {
    await run(`st().updateSettings({ addressBar: "toolbar" }); return settle(900);`);
    const beforeDrag = await untilSnapshot("header drag counter before click", (_, snapshot) => Number.isInteger(snapshot.windowDragCount));
    const beforeCount = beforeDrag.windowDragCount;
    const out = await run(`const x = 172, y = 20;
      const o = {};
      return act("hit:" + x + "," + y).then((h) => { o.hit = h; return act("windowDrags"); })
        .then(() => click(x, y)).then(() => settle(300)).then(() => act("windowDrags")).then((d) => { o.drags = Number(String(d).split("\\n")[0]); return frame(); })
        .then((f) => { o.before = f; return o; });`);
    await untilSnapshot("header drag counter after click", (_, snapshot) => snapshot.windowDragCount - beforeCount === out.drags);
    out.after = await run(`return click(172, 20).then(() => click(172, 20, 2)).then(() => settle(900)).then(frame);`);
    if (!/SidebarChromeView/.test(out.hit) || out.drags !== 1 || JSON.stringify(out.after) === JSON.stringify(out.before)) throw new Error(JSON.stringify(out));
    const afterFrame = out.after.replace(/[{}]/g, "").split(",").map(Number);
    await untilSnapshot("header drag window frame", (window) => window?.sidebarShell?.chrome?.header === 46 &&
      Math.abs(window.frame.width - afterFrame[2]) <= 0.5 && Math.abs(window.frame.height - afterFrame[3]) <= 0.5);
    await run(`return click(172, 20).then(() => click(172, 20, 2)).then(() => settle(900)).then(() => { st().updateSettings({ addressBar: "sidebar" }); return settle(900); });`);
    return out;
  });
  await canary("(a)");

  await rep.check("(b) the address bar sits in the slot, survives toggling out and back and a reload, and opens the dropdown", async () => {
    const sample = () => run(`return globalThis.expo.modules.SolaraSidebarAddressBar.sample("w1").then((s) => s && JSON.parse(s));`);
    const first = await sample();
    await untilSnapshot("sidebar address at launch", (window) =>
      window?.sidebarAddressBar?.claimed === first.claimed && window.sidebarAddressBar.inWindow === first.inWindow);
    await run(`st().updateSettings({ addressBar: "toolbar" }); return settle(900);`);
    const off = await run(`return col().then((c) => c?.chrome?.header ?? null);`);
    await untilSnapshot("address bar outside sidebar", (window) => window?.sidebarShell?.chrome?.header === off &&
      (window?.sidebarAddressBar == null || window.sidebarAddressBar.claimed === false));
    await run(`st().updateSettings({ addressBar: "sidebar" }); return settle(900);`);
    const back = await sample();
    await untilSnapshot("address bar restored", (window) =>
      window?.sidebarAddressBar?.claimed === back.claimed && window.sidebarAddressBar.inWindow === back.inWindow);
    await run(`ac.reload?.(); return settle(3000);`).catch(() => null);
    await sleep(2000);
    const reloaded = await sample();
    await untilSnapshot("address bar after reload", (window) =>
      window?.sidebarAddressBar?.claimed === reloaded.claimed && window.sidebarAddressBar.inWindow === reloaded.inWindow);
    const c = await run(`return col();`);
    const opened = await run(`const [x, y] = [${Math.round(c0.frame[0] + 80)}, ${Math.round(c0.frame[1] + 62)}];
      return click(x, y).then(() => settle(700)).then(() => ({ panel: !!st().windowUi.w1?.panel.open }));`);
    await untilSnapshot("address panel opened", (window) => window?.sidebarShell?.chrome?.header === c?.chrome?.header);
    await run(`st().closePanel("w1"); return settle(400);`);
    const out = { first, off, back, reloaded, header: c?.chrome?.header, opened };
    for (const s of [first, back, reloaded]) if (!s?.claimed || !s?.inWindow) throw new Error(JSON.stringify(out));
    if (off !== 46 || out.header !== 80 || !opened.panel) throw new Error(JSON.stringify(out));
    return out;
  });
  await canary("(b)");

  await rep.check("(c) the downloads buttons open the downloads list", async () => {
    const out = {};
    await run(`st().upsertDownload({ id: "d1", url: "https://example.com/a.pdf", filename: "a.pdf", path: "/tmp/a.pdf", state: "finished", paused: false, received: 1, total: 1, speed: 0, mimeType: "application/pdf" }); return settle(300).then(() => { st().setDownloadsOpen("w1", false); return settle(900); });`);
    await untilSnapshot("seeded download", (_, state) => state.downloads.count === 1 && state.downloads.finished === 1);
    for (const mode of ["sidebar", "toolbar"]) {
      await run(`st().updateSettings({ addressBar: "${mode}" }); return settle(900);`);
      const c = await run(`return col();`);
      const r = c?.chrome?.headerDownloads ?? c?.chrome?.footerDownloads;
      if (!r) { out[mode] = { missing: c?.chrome }; continue; }
      await checkColumn(`downloads button in ${mode}`, c);
      const [x, y] = centre(c, r);
      out[mode] = await run(`return click(${x}, ${y}).then(() => settle(500)).then(() => !!st().windowUi.w1?.downloadsOpen);`);
      await untilSnapshot(`downloads open in ${mode}`, (window) => window?.overlays?.some((overlay) => overlay.kind === "downloads"));
      await run(`st().setDownloadsOpen("w1", false); return settle(300);`);
    }
    await run(`st().removeDownload("d1"); st().updateSettings({ addressBar: "sidebar" }); return settle(900);`);
    if (out.sidebar !== true || out.toolbar !== true) throw new Error(`seed a download first if a button is missing: ${JSON.stringify(out)}`);
    return out;
  });
  await canary("(c)");

  await rep.check("(d) the resize handle drags the width live, keeps it on release, and a double-click resets it", async () => {
    const c = await run(`return col();`);
    const [x, y] = centre(c, c.chrome.resize);
    const out = await run(`const o = { saved: st().settings.sidebarWidth ?? 190 };
      return act("mouse:down:${x},${y},1").then(() => act("mouse:dragged:${x + 20},${y}")).then(() => act("mouse:dragged:${x + 40},${y}")).then(() => settle(200))
        .then(() => col()).then((c) => ({ ...o, live: c.frame[2] }));`);
    try {
      await untilSnapshot("sidebar resize live width", (window) =>
        Math.abs(window?.sidebarChromeMetrics?.liveWidth - out.live) <= 0.5 &&
        Math.abs(window?.sidebarChromeMetrics?.committedWidth - out.saved) <= 0.5);
    } finally {
      await run(`return act("mouse:up:${x + 40},${y},1").then(() => settle(500));`);
    }
    Object.assign(out, await run(`const committed = st().settings.sidebarWidth; return col().then((c) => ({ committed, after: c.frame[2] }));`));
    await untilSnapshot("sidebar resize committed width", (window) =>
      Math.abs(window?.sidebarChromeMetrics?.liveWidth - out.after) <= 0.5 &&
      Math.abs(window?.sidebarChromeMetrics?.committedWidth - out.committed) <= 0.5);
    out.reset = await run(`return click(${x + 40}, ${y}).then(() => click(${x + 40}, ${y}, 2)).then(() => settle(600)).then(() => st().settings.sidebarWidth);`);
    if (!(out.live > out.saved + 30) || !(Math.abs(out.committed - out.after) < 1) || out.reset !== 190) throw new Error(JSON.stringify(out));
    await untilSnapshot("sidebar resize reset", (window) => Math.abs(window?.sidebarShell?.frame?.[2] - out.reset) <= 0.5 &&
      Math.abs(window?.sidebarChromeMetrics?.committedWidth - out.reset) <= 0.5);
    return out;
  });
  await canary("(d)");

  await rep.check("(e) the footer's profile dots switch profiles", async () => {
    const c = await run(`return col();`);
    const dot = c.chrome.dots.find((d) => d.id === "work");
    if (!dot) throw new Error(`no dot: ${JSON.stringify(c.chrome.dots)}`);
    const [x, y] = centre(c, dot.rect);
    const out = await run(`return click(${x}, ${y}).then(() => settle(1200)).then(() => st().windows.w1.profileId);`);
    await untilSnapshot("profile dot selects work", (window) => window?.profileId === out);
    await run(`st().switchProfile("w1", "default"); return settle(1200);`);
    if (out !== "work") throw new Error(`profile ${out}`);
    return out;
  });
  await canary("(e)");

  await rep.check("(f) a drop on the header and on the footer opens a tab, with the native glow", async () => {
    const out = {};
    for (const [name, y] of [["header", 30], ["footer", 800 - 12]]) {
      out[name] = await run(`const FD = ac.shell.devFileDrag; const before = Object.keys(st().tabs).length;
        return FD.drag("w1", "move", 120, ${y}, { urls: ["https://example.com/${name}"] }).then(() => settle(400))
          .then(() => FD.drag("w1", "drop", 120, ${y})).then(() => settle(900)).then(() => ({ added: Object.keys(st().tabs).length - before }));`);
    }
    out.total = await run(`return Object.keys(st().tabs).length;`);
    await untilSnapshot("header and footer dropped tabs", (_, state) => state.tabs.length === out.total);
    await run(`const T = globalThis.acTabDrag; globalThis.__dropGlowWas = T.getState(); T.setState({ overWindow: "w1" }); return true;`);
    let glowOn;
    try {
      await sleep(400);
      glowOn = await run(`return col().then((c) => c.chrome.dropGlow);`);
      await untilSnapshot("sidebar drop glow on", (window) => Math.abs(window?.sidebarShell?.chrome?.dropGlow - glowOn) <= 0.05);
    } finally {
      await run(`globalThis.acTabDrag.setState({ overWindow: globalThis.__dropGlowWas.overWindow }); return true;`);
    }
    await sleep(400);
    const glowOff = await run(`return col().then((c) => c.chrome.dropGlow);`);
    await untilSnapshot("sidebar drop glow off", (window) => Math.abs(window?.sidebarShell?.chrome?.dropGlow - glowOff) <= 0.05);
    out.glow = [glowOn, glowOff];
    if (out.header.added !== 1 || out.footer.added !== 1 || !(out.glow[0] > 0.9) || !(out.glow[1] < 0.1)) throw new Error(JSON.stringify(out));
    return out;
  });
  await canary("(f)");

  await rep.check("(g) with the column off (top tabs), RN's header, footer and glow are back", async () => {
    await run(`st().updateSettings({ tabLayout: "top" }); return settle(1500);`);
    const off = await run(`return col();`);
    await untilSnapshot("column hidden with top tabs", (window) => window?.sidebarShell == null);
    await run(`st().updateSettings({ tabLayout: "sidebar" }); return settle(1500);`);
    const back = await run(`return col();`);
    await checkColumn("column restored with sidebar tabs", back);
    if (off !== null || !back?.chrome) throw new Error(JSON.stringify({ off, back: !!back }));
    return { off, back: !!back.chrome };
  });
} catch (e) {
  rep.record("run", { error: e });
} finally {
  await inst?.quit().catch(() => {});
  if (!keep && rep.disposable) rmSync(scratch, { recursive: true, force: true });
}
const failed = rep.results.filter((r) => !r.ok);
console.log(`${rep.results.length - failed.length}/${rep.results.length} passed${failed.length ? `; log ${rep.logFile}` : ""}`);
process.exit(failed.length ? 1 : 0);

import { cpSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { execFileSync } from "node:child_process";
import { createServer } from "node:http";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { devtools, launch, reporter, session, sleep } from "../../../scripts/lib/instance.mjs";

const args = process.argv.slice(2);
const appArg = args.find((a) => !a.startsWith("--"));
if (!appArg) {
  console.error(`usage: node side-panel-test.mjs <Debug Solara.app> [--keep-data] [--legs rn,native,pool]

An extension's side panel drawn by RN and natively (SOLARA_NATIVE_SIDE_PANEL=1), each with the page pool off and on. In
each leg a fixture MV3 extension with a side_panel opens its panel in window w1 and the test checks: the card sits
where RN's does and the panel page gets the same size; a drag on the grip resizes it and the width is saved; a
double-click on the grip resets it to 360; the page's window.close() closes it; its window.open() opens a tab; the ✕
closes it. Focus: with the panel page focused, closing it by the ✕, by the toolbar toggle and by replacing it with
another extension's panel leaves page A focused (the native panel; RN's legs only record where focus went). Lifetime: twelve open and close cycles leave no panel page alive
(DevTools targets) and no more renderer processes than before; a replaced panel, a JS reload, a closed window and a
turned-off extension each leave at most the one panel page that should be there.`);
  process.exit(2);
}
const keep = args.includes("--keep-data");
const legsArg = args.includes("--legs") ? args[args.indexOf("--legs") + 1] : null;
const scratch = mkdtempSync(join(tmpdir(), "ac-side-panel-"));
const rep = reporter(join(scratch, "side-panel-test.log"), { name: "side-panel-test" });

const fixtureExt = resolve(dirname(fileURLToPath(import.meta.url)), "../../../packages/solaracore/scripts/fixtures/ext");
const extA = join(scratch, "ext-a");
const extB = join(scratch, "ext-b");
for (const [dir, name] of [[extA, "Side panel A"], [extB, "Side panel B"]]) {
  cpSync(fixtureExt, dir, { recursive: true });
  const manifest = JSON.parse(readFileSync(join(dir, "manifest.json"), "utf8"));
  manifest.name = name;
  delete manifest.content_scripts;
  delete manifest.declarative_net_request;
  manifest.permissions = ["sidePanel"];
  writeFileSync(join(dir, "manifest.json"), JSON.stringify(manifest));
  writeFileSync(join(dir, "panel.html"), `<!doctype html><meta charset="utf-8"><title>${name}</title><body style="margin:0"><input id="field" style="width:100%">${name}</body>`);
}

const server = createServer((req, res) => {
  res.writeHead(200, { "content-type": "text/html" });
  const name = req.url.slice(1) || "a";
  res.end(`<!doctype html><title>${name.toUpperCase()}</title><link rel="icon" href="data:,"><body><input id="field">${name}</body>`);
});
await new Promise((r) => server.listen(0, "127.0.0.1", r));
const origin = `http://127.0.0.1:${server.address().port}`;
const fixture = session({
  windows: [
    { id: "w1", frame: [80, 80, 1280, 800], activeTabIds: { default: "a" } },
    { id: "w2", frame: [140, 140, 1000, 700], activeTabIds: { default: "b" } },
  ],
  tabs: [{ id: "a", url: `${origin}/a`, title: "A", windowId: "w1" }, { id: "b", url: `${origin}/b`, title: "B", windowId: "w2" }],
  settings: { warnBeforeClosingLastTab: false, warnBeforeClosingWindow: false },
});

const HELPERS = `
const C = globalThis.expo.modules.SolaraCEF;
const X = globalThis.expo.modules.SolaraExtensions;
const settle = (ms) => new Promise((r) => setTimeout(r, ms));
const fibers = (name) => acPerf.findFibers(name, 500).filter((f) => !!f.child);
const hostOf = (fiber) => { let f = fiber; while (f && !(f.stateNode && f.stateNode.measureInWindow)) f = f.child; return f && f.stateNode; };
const measure = (fiber) => new Promise((r) => { const n = hostOf(fiber); return n ? n.measureInWindow((x, y, w, h) => r([x, y, w, h])) : r(null); });
const act = (n, a) => C.devWindow(n, a);
const at = (p) => Math.round(p[0]) + "," + Math.round(p[1]);
const click = (n, p, count) => act(n, "mouse:moved:" + at(p)).then(() => settle(40))
  .then(() => act(n, "mouse:down:" + at(p) + "," + (count || 1))).then(() => settle(40)).then(() => act(n, "mouse:up:" + at(p) + "," + (count || 1)));
const drag = (n, from, dx) => act(n, "mouse:moved:" + at(from)).then(() => settle(40)).then(() => act(n, "mouse:down:" + at(from)))
  .then(() => [1, 2, 3, 4, 5].reduce((p, i) => p.then(() => settle(30)).then(() => act(n, "mouse:dragged:" + at([from[0] + dx * i / 5, from[1]]))), Promise.resolve()))
  .then(() => settle(40)).then(() => act(n, "mouse:up:" + at([from[0] + dx, from[1]])));
const shown = (w) => ac.extensions.useExtensions.getState().sidePanels[w] || null;
const width = () => ac.store.getState().settings.extensionSidePanelWidth ?? 360;
const card = () => {
  const [rn] = fibers("PanelCard");
  if (rn) return measure(rn);
  const [nat] = fibers("NativePanelCard");
  return nat ? measure(nat).then((f) => f && [f[0] + f[2] - width(), f[1], width(), f[3]]) : Promise.resolve(null);
};
`;
let app = null;
const run = (body, timeout = 20000) => app.eval(`${HELPERS}\n${body}`, { timeout });
const until = async (what, test, ms = 8000) => {
  const end = Date.now() + ms;
  let last;
  while (Date.now() < end) {
    last = await (typeof test === "string" ? run(test) : test()).catch((e) => ({ error: String(e.message ?? e) }));
    if (last && !last.error) return last;
    await sleep(150);
  }
  throw new Error(`${what}: never true (last ${JSON.stringify(last)})`);
};
const near = (a, b) => a && b && a.length === b.length && a.every((v, i) => Math.abs(v - b[i]) <= 0.5);
const centre = (f) => [f[0] + f[2] / 2, f[1] + f[3] / 2];
const closeButton = (f) => [f[0] + f[2] - 5 - 15, f[1] + 20];
const grip = (f) => [f[0] + 0.5, f[1] + f[3] / 2];
const pageCentre = (f) => [f[0] + f[2] / 2, f[1] + 41 + (f[3] - 41) / 2];

const panelTargets = async (id) => (await app.targets()).filter((t) => t.url.startsWith(`chrome-extension://${id}/panel.html`));
const renderers = () => {
  try {
    return execFileSync("pgrep", ["-P", String(app.pid), "-f", "type=renderer"], { encoding: "utf8" }).trim().split("\n").filter(Boolean).length;
  } catch {
    return 0;
  }
};
const focused = async (urlPart) => {
  const target = await app.pageTarget(urlPart);
  if (!target) return null;
  const page = await devtools(target);
  try {
    return await page.eval("document.hasFocus()");
  } finally {
    page.close();
  }
};

const LEGS = [
  { tag: "rn", env: { SOLARA_NATIVE_SHELL: "1", SOLARA_NATIVE_SIDE_PANEL: "0" } },
  { tag: "rn-pool", env: { SOLARA_NATIVE_SHELL: "1", SOLARA_NATIVE_SIDE_PANEL: "0", SOLARA_NATIVE_PAGES_POOL: "1", SOLARA_SHELL_PANES: "1", SOLARA_TAB_POOL: "1" } },
  { tag: "native", env: { SOLARA_NATIVE_SHELL: "1", SOLARA_NATIVE_SIDE_PANEL: "1", SOLARA_NATIVE_PAGES_POOL: "0" } },
  { tag: "pool", env: { SOLARA_NATIVE_SHELL: "1", SOLARA_NATIVE_SIDE_PANEL: "1", SOLARA_NATIVE_PAGES_POOL: "1", SOLARA_SHELL_PANES: "1", SOLARA_TAB_POOL: "1" } },
].filter((l) => !legsArg || legsArg.split(",").includes(l.tag));
const measured = {};

try {
  for (const { tag, env } of LEGS) {
    app = await launch(resolve(appArg), {
      data: join(scratch, `data-${tag}`), fresh: true, session: fixture, onboarded: true, probe: true, env,
      ready: "return !!ac.store.getState().windows.w1",
    });
    await until("page A", `return ac.store.getState().tabs.a?.title === "A" || null;`, 15000);
    const number = await until("window w1", `const id = Object.entries(ac.pageState.getState().browsers ?? {}).find(([, t]) => t === "a")?.[0]; return id ? C.devWindowNumber(Number(id)) : null;`, 15000);
    const rnPanel = tag.startsWith("rn");
    const kinds = await run(`return globalThis.expo.modules.SolaraHosted?.kinds?.() ?? [];`);
    if (!rnPanel !== kinds.includes("extensionSidePanel")) throw new Error(`${tag}: hosted kinds ${JSON.stringify(kinds)}`);
    if (tag.endsWith("pool")) {
      const served = await run(`return !!globalThis.expo.modules.SolaraTabPool?.available?.() && !!ac.webviews.get("a") && !acPerf.findFibers("TabWebView", 5).length;`);
      if (!served) throw new Error("the pool doesn't serve page A");
    }
    const a = await run(`return X.install(${JSON.stringify(extA)}, "");`);
    const b = await run(`return X.install(${JSON.stringify(extB)}, "");`);
    await run(`return ac.extensions.refreshExtensions("").then(() => true);`);
    const open = (id, w = "w1") => run(`return ac.extensions.openSidePanel(${JSON.stringify(w)}, ${JSON.stringify(id)}).then(() => !!shown(${JSON.stringify(w)}));`);
    const openAndLoad = async (id, w = "w1") => {
      await until(`${id}'s panel opens`, () => open(id, w), 8000);
      await until(`${id}'s panel page loads`, async () => (await panelTargets(id)).length === 1 || null, 8000).catch(async (e) => {
        const all = (await app.targets()).map((t) => `${t.type} ${t.url}`);
        throw new Error(`${e.message}; shown ${JSON.stringify(await run(`return shown(${JSON.stringify(w)});`))}; targets ${JSON.stringify(all)}`);
      });
      await sleep(400);
    };
    const closedWithFocusOnA = async (how) => {
      await until(`${how}: the panel closes`, `return !shown("w1") || null;`, 4000);
      if (rnPanel) return { pageAFocused: await sleep(600).then(() => focused(`${origin}/a`)) };
      return until(`${how}: page A has focus`, async () => (await focused(`${origin}/a`)) || null, 3000);
    };
    const focusPanel = async (id) => {
      const f = await run(`return card();`);
      await run(`return click(${number}, ${JSON.stringify(pageCentre(f))}).then(() => true);`);
      await until("the panel page has focus", async () => (await focused(`chrome-extension://${id}/panel.html`)) || null, 3000).catch(async (e) => {
        const p = pageCentre(f);
        const hit = await run(`return act(${number}, "hit:${Math.round(p[0])},${Math.round(p[1])}");`).catch((x) => String(x));
        const responders = await run(`return act(${number}, "responders:");`).catch((x) => String(x));
        throw new Error(`${e.message}; card ${JSON.stringify(f)}; hit ${JSON.stringify(hit)}; responders ${JSON.stringify(responders)}`);
      });
    };
    const baseline = renderers();

    await rep.check(`${tag}-opens`, async () => {
      await run(`ac.store.getState().updateSettings({ extensionSidePanelWidth: 360 }); return true;`);
      await openAndLoad(a.id);
      const frame = await until("the card", `return card();`, 4000);
      const page = await (await app.page(`chrome-extension://${a.id}/panel.html`)).eval("[innerWidth, innerHeight]");
      measured[tag] = { frame, page };
      return { frame, page };
    });

    await rep.check(`${tag}-grip-resizes`, async () => {
      const f = await run(`return card();`);
      await run(`return drag(${number}, ${JSON.stringify(grip(f))}, -80).then(() => true);`);
      const w = await until("the width is saved", `return width() !== 360 ? width() : null;`, 3000);
      if (Math.abs(w - 440) > 1) throw new Error(`width ${w} after an 80 point drag`);
      await until("the card follows", `return card().then((c) => c && Math.abs(c[2] - ${w}) < 1 || null);`, 3000);
      const g = await run(`return card();`);
      await run(`return click(${number}, ${JSON.stringify(grip(g))}, 1).then(() => click(${number}, ${JSON.stringify(grip(g))}, 2)).then(() => true);`);
      await until("a double-click resets it", `return width() === 360 || null;`, 3000);
      return w;
    });

    await rep.check(`${tag}-window-open`, async () => {
      const before = await run(`return Object.keys(ac.store.getState().tabs).length;`);
      const panel = await app.page(`chrome-extension://${a.id}/panel.html`);
      await panel.eval(`window.open(${JSON.stringify(`${origin}/opened`)}); true`, { userGesture: true });
      panel.close();
      return until("a new tab", `return Object.values(ac.store.getState().tabs).some((t) => (t.url || "").endsWith("/opened")) && Object.keys(ac.store.getState().tabs).length > ${before} || null;`, 5000);
    });
    await run(`const t = Object.values(ac.store.getState().tabs).find((t) => (t.url || "").endsWith("/opened")); if (t) ac.store.getState().closeTab(t.id); ac.store.getState().setActiveTab?.("w1", "a"); return true;`).catch(() => null);
    await sleep(300);

    await rep.check(`${tag}-focus-close-button`, async () => {
      await openAndLoad(a.id);
      await focusPanel(a.id);
      const f = await run(`return card();`);
      await run(`return click(${number}, ${JSON.stringify(closeButton(f))}).then(() => true);`);
      return closedWithFocusOnA("✕");
    });

    await rep.check(`${tag}-focus-toolbar-toggle`, async () => {
      await openAndLoad(a.id);
      await focusPanel(a.id);
      await run(`return Promise.resolve(ac.extensions.toggleSidePanel("w1", ${JSON.stringify(a.id)})).then(() => true);`);
      return closedWithFocusOnA("toggle");
    });

    await rep.check(`${tag}-focus-replace`, async () => {
      await openAndLoad(a.id);
      await focusPanel(a.id);
      await openAndLoad(b.id);
      await until("A's panel page goes", async () => (await panelTargets(a.id)).length === 0 || null, 4000);
      const onA = rnPanel
        ? { pageAFocused: await sleep(600).then(() => focused(`${origin}/a`)) }
        : await until("page A has focus after the replace", async () => (await focused(`${origin}/a`)) || null, 3000);
      await run(`ac.extensions.closeSidePanel("w1"); return true;`);
      await until("B's panel page goes", async () => (await panelTargets(b.id)).length === 0 || null, 4000);
      return onA;
    });

    await rep.check(`${tag}-cycles`, async () => {
      for (let i = 0; i < 12; i++) {
        await openAndLoad(i % 2 ? b.id : a.id);
        await run(`ac.extensions.closeSidePanel("w1"); return true;`);
        await until("the panel closes", `return !shown("w1") || null;`, 4000);
      }
      await until("no panel page is left", async () => (await panelTargets(a.id)).length + (await panelTargets(b.id)).length === 0 || null, 5000);
      const after = await until("renderers settle", async () => (renderers() <= baseline + 1 ? renderers() : null), 8000).catch(() => renderers());
      if (after > baseline + 1) throw new Error(`renderers ${baseline} before, ${after} after twelve cycles`);
      return { baseline, after };
    });

    await rep.check(`${tag}-closed-window`, async () => {
      await openAndLoad(a.id, "w2");
      await run(`ac.store.getState().closeWindow("w2"); return true;`);
      return until("w2's panel page goes", async () => (await panelTargets(a.id)).length === 0 || null, 5000);
    });

    await rep.check(`${tag}-turned-off`, async () => {
      await openAndLoad(a.id);
      await run(`return ac.extensions.setEnabled("", ${JSON.stringify(a.id)}, false).then(() => true);`);
      await until("the panel closes", `return !shown("w1") || null;`, 5000);
      await until("its page goes", async () => (await panelTargets(a.id)).length === 0 || null, 5000);
      await run(`return ac.extensions.setEnabled("", ${JSON.stringify(a.id)}, true).then(() => true);`);
      return true;
    });

    await rep.check(`${tag}-js-reload`, async () => {
      await openAndLoad(b.id);
      await run(`setTimeout(() => { try { globalThis.nativeModuleProxy.DevSettings.reload(); } catch {} }, 50); return true;`);
      await sleep(1500);
      await app.ready({ timeout: 60000, test: "return !!ac.store.getState().windows.w1" });
      await sleep(1500);
      const left = (await panelTargets(b.id)).length;
      if (left > 1) throw new Error(`${left} panel pages after a JS reload`);
      await run(`ac.extensions.closeSidePanel("w1"); return true;`);
      await until("no panel page after closing", async () => (await panelTargets(b.id)).length === 0 || null, 5000);
      return left;
    });

    await rep.check(`${tag}-window-close`, async () => {
      if (!(await run(`return !!shown("w1");`))) await openAndLoad(a.id);
      const panel = await app.page(`chrome-extension://${a.id}/panel.html`);
      await panel.eval("window.close(); true").catch(() => null);
      panel.close();
      await until("window.close() closes the panel", `return !shown("w1") || null;`, 4000);
      return until("its page goes", async () => (await panelTargets(a.id)).length === 0 || null, 4000);
    });

    await app.quit();
    app = null;
  }

  for (const tag of ["native", "pool"]) {
    if (!measured.rn || !measured[tag]) continue;
    await rep.check(`${tag}-matches-rn`, async () => {
      if (!near(measured[tag].frame, measured.rn.frame)) throw new Error(`card ${measured[tag].frame}, RN ${measured.rn.frame}`);
      if (!near(measured[tag].page, measured.rn.page)) throw new Error(`panel page ${measured[tag].page}, RN ${measured.rn.page}`);
      return measured.rn;
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

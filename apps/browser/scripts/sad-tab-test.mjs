import { mkdtempSync, rmSync } from "node:fs";
import { createServer } from "node:http";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { devtools, launch, reporter, session, sleep } from "../../../scripts/lib/instance.mjs";

const args = process.argv.slice(2);
const appArg = args.find((a) => !a.startsWith("--"));
if (!appArg) {
  console.error(`usage: node sad-tab-test.mjs <Debug Solara.app> [--keep-data]

The sad tab over a local page, drawn by RN and then natively (SOLARA_NATIVE_SHELL=1, where SadTabView sits in a
container on top of the shell's card, framed to the pane): a crashed tab covers the pane with "This tab needs to
reload" and a Reload button, an unresponsive one dims it under a 320 wide card with Exit Page and Wait. The native
overlay, its buttons and RN's are the same frames in the window (within half a point: one pixel of Yoga rounding), a click on Reload clears the
crash and a click on Wait clears the hang, and once both are gone the native container leaves the card. A third instance
serves the page from the pool (SOLARA_NATIVE_PAGES_POOL=1 SOLARA_SHELL_PANES=1): the renderer really crashes
(chrome://crash through the pooled handle) and really hangs (a 40 second busy loop and a key press), both reach the
store as page events, the native sad tab sits where RN's does, Reload reloads the pooled page back to A and Wait clears
the hang. A fourth adds SOLARA_NATIVE_PANE_PROMPTS=1: RN no longer mounts
its SadTab wrapper for the pooled pane at all, the native sad tab comes from the pool's page events alone (a real
renderer crash, then a real hang: a 40 second busy loop and a key press, so onUnresponsive comes from the engine), it
stays up while JS publishes an unrelated pane overlay (the zoom popover), and Reload and Wait clear it.`);
  process.exit(2);
}
const keep = args.includes("--keep-data");
const scratch = mkdtempSync(join(tmpdir(), "ac-sad-tab-"));
const rep = reporter(join(scratch, "sad-tab-test.log"), { name: "sad-tab-test" });

const server = createServer((req, res) => {
  res.writeHead(200, { "content-type": "text/html" });
  res.end(`<!doctype html><title>A</title><link rel="icon" href="data:,"><body>a</body>`);
});
await new Promise((r) => server.listen(0, "127.0.0.1", r));
const pageUrl = `http://127.0.0.1:${server.address().port}/a`;
const fixture = session({
  windows: [{ id: "w1", frame: [80, 80, 1280, 800], activeTabIds: { default: "a" } }],
  tabs: [{ id: "a", url: pageUrl, title: "A" }],
  settings: { warnBeforeClosingLastTab: false, warnBeforeClosingWindow: false },
});

const HELPERS = `
const C = globalThis.expo.modules.SolaraCEF;
const M = globalThis.expo.modules.SolaraMedia;
const settle = (ms) => new Promise((r) => setTimeout(r, ms));
const page = () => ac.pageState.getState().pages.a || {};
const patch = (p) => ac.pageState.setState((s) => ({ pages: { ...s.pages, a: { ...(s.pages.a || {}), ...p } } }));
const fibers = (name) => acPerf.findFibers(name, 500).filter((f) => !!f.child);
const hostOf = (fiber) => { let f = fiber; while (f && !(f.stateNode && f.stateNode.measureInWindow)) f = f.child; return f && f.stateNode; };
const measure = (fiber) => new Promise((r) => { const n = hostOf(fiber); return n ? n.measureInWindow((x, y, w, h) => r([x, y, w, h])) : r(null); });
const button = (title) => { const f = fibers("PromptButton").find((b) => b.memoizedProps.title === title); return f ? measure(f) : Promise.resolve(null); };
const act = (n, a) => C.devWindow(n, a);
const click = (n, p) => act(n, "mouse:moved:" + p[0] + "," + p[1]).then(() => settle(60))
  .then(() => act(n, "mouse:down:" + p[0] + "," + p[1])).then(() => settle(60)).then(() => act(n, "mouse:up:" + p[0] + "," + p[1]));
const native = (w = "w1") => M && M.describePaneOverlays ? M.describePaneOverlays(w).then(JSON.parse) : Promise.resolve(null);
const sadIn = (w) => native(w).then((d) => !!(d && d.tabs && d.tabs.a && d.tabs.a.sadTab && !d.tabs.a.sadTab.hidden));
`;
let app = null;
const run = (body, timeout = 20000) => app.eval(`${HELPERS}\n${body}`, { timeout });
const until = async (what, body, ms = 8000) => {
  const end = Date.now() + ms;
  let last;
  while (Date.now() < end) {
    last = await run(body).catch((e) => ({ error: String(e.message ?? e) }));
    if (last && !last.error) return last;
    await sleep(150);
  }
  throw new Error(`${what}: never true (last ${JSON.stringify(last)})`);
};
const untilSnapshot = async (what, accept, ms = 5000) => {
  const end = Date.now() + ms;
  let last;
  while (Date.now() < end) {
    last = await app.snapshot().catch((error) => ({ error: error.message }));
    if (!last.error && accept(last)) return last;
    await sleep(100);
  }
  throw new Error(`${what}: native snapshot never matched (${JSON.stringify(last)})`);
};
const nativeSad = (state, windowId = "w1") => state.windows.find((window) => window.id === windowId)?.overlays.find((overlay) => overlay.kind === "sadTab" && overlay.tabId === "a");
const nativeFrame = (frame) => frame && [frame.x, frame.y, frame.width, frame.height];
const near = (a, b) => a && b && a.length === b.length && a.every((v, i) => Math.abs(v - b[i]) <= 0.5);
const centre = (f) => [Math.round(f[0] + f[2] / 2), Math.round(f[1] + f[3] / 2)];

const modes = [
  { crashed: { url: pageUrl, reason: "test" } },
  { unresponsive: true },
];
const labels = { 0: ["Reload"], 1: ["Exit Page", "Wait"] };
const measured = { rn: [], native: [], pool: [], prompts: [] };
const LEGS = [
  { tag: "rn", env: { SOLARA_NATIVE_SHELL: "0", SOLARA_NATIVE_PAGES_POOL: "0", SOLARA_SHELL_PANES: "0", SOLARA_NATIVE_PANE_PROMPTS: "0" } },
  { tag: "native", env: { SOLARA_NATIVE_SHELL: "1", SOLARA_NATIVE_PAGES_POOL: "0", SOLARA_SHELL_PANES: "0" } },
  { tag: "pool", env: { SOLARA_NATIVE_SHELL: "1", SOLARA_NATIVE_PAGES_POOL: "1", SOLARA_SHELL_PANES: "1", SOLARA_TAB_POOL: "1" } },
  { tag: "prompts", env: { SOLARA_NATIVE_SHELL: "1", SOLARA_NATIVE_PAGES_POOL: "1", SOLARA_SHELL_PANES: "1", SOLARA_TAB_POOL: "1", SOLARA_NATIVE_PANE_PROMPTS: "1" } },
];

async function frames(nativeShell, i) {
  if (!nativeShell) {
    const overlay = await until("RN's sad tab", `const [f] = fibers("SadTab"); return f ? measure(f) : null;`);
    const controls = {};
    for (const title of labels[i]) controls[title] = await until(`RN's ${title}`, `return button(${JSON.stringify(title)});`);
    return { overlay, controls };
  }
  const info = await until("the native sad tab", `return native().then((d) => d && d.tabs.a && d.tabs.a.sadTab && !d.tabs.a.sadTab.hidden ? d : null);`);
  if (!info.top || !info.inCard) throw new Error(`the overlay container is not the card's top child: ${JSON.stringify(info)}`);
  const drawn = await run(`return fibers("PromptButton").length + fibers("Symbol").filter((f) => f.memoizedProps.name === "exclamationmark.triangle").length;`);
  if (drawn) throw new Error("RN still draws the sad tab's icon or buttons with the native one on");
  return { overlay: info.tabs.a.sadTab.frame, controls: info.tabs.a.sadTab.controls, mode: info.tabs.a.sadTab.mode };
}

try {
  for (const { tag, env } of LEGS) {
    const nativeShell = tag !== "rn";
    const prompts = tag === "prompts";
    const pooled = tag === "pool" || prompts;
    app = await launch(resolve(appArg), {
      data: join(scratch, `data-${tag}`), fresh: true, session: fixture, onboarded: true, probe: true, env,
      ready: "return !!ac.store.getState().windows.w1",
    });
    const number = await until("the window", `return C.chromeWindows().then((ws) => ws.find((w) => w.visible)?.window ?? null);`, 15000);
    await until("page A", `return ac.store.getState().tabs.a?.title === "A" || null;`, 15000);
    if (pooled) {
      const served = await run(`return !!globalThis.expo.modules.SolaraTabPool?.available?.() && !!ac.webviews.get("a") && !acPerf.findFibers("TabWebView", 5).length;`);
      if (!served) throw new Error("the pool doesn't serve page A");
    }
    if (prompts) {
      const kinds = await run(`return globalThis.expo.modules.SolaraHosted.kinds();`);
      if (!kinds.includes("panePrompts")) throw new Error(`panePrompts not declared: ${JSON.stringify(kinds)}`);
    }

    for (const [i, state] of modes.entries()) {
      const name = i === 0 ? "crashed" : "unresponsive";
      await rep.check(`${tag}-${name}`, async () => {
        if (pooled && i === 0) {
          await run(`ac.webviews.get("a").loadUrl("chrome://crash"); return true;`);
          await until("the crash reaches the store", `return page().crashed || null;`, 8000);
        } else if (pooled) {
          const target = await app.pageTarget(pageUrl);
          if (!target) throw new Error("no DevTools target for page A");
          const cdp = await devtools(target);
          await cdp.eval("setTimeout(() => { const end = Date.now() + 40000; while (Date.now() < end); }, 50); true", { awaitPromise: false }).finally(() => cdp.close());
          await sleep(500);
          await run(`return ac.shell.devKeyEquivalent("w1", { key: "a", keyCode: 0, modifiers: [], focus: "page" }).then(() => true);`);
        } else await run(`patch(${JSON.stringify(state)}); return true;`);
        await sleep(400);
        if (pooled && !prompts) await until(`the ${name} page reaches the store`, `const p = page(); return (${i === 0} ? p.crashed : p.unresponsive) || null;`, 35000);
        if (prompts) {
          await until("the native sad tab", `return native().then((d) => d && d.tabs.a && d.tabs.a.sadTab && !d.tabs.a.sadTab.hidden && d.tabs.a.sadTab.mode === ${JSON.stringify(name)} || null);`, 35000);
          const wrappers = await run(`return acPerf.findFibers("SadTab", 5).length;`);
          if (wrappers) throw new Error(`RN still mounts ${wrappers} SadTab wrapper(s) with the pane prompts switch on`);
          await run(`ac.pageState.setState((s) => ({ popover: { ...s.popover, a: "zoom" } })); return true;`);
          await sleep(600);
          const kept = await run(`return native().then((d) => !!(d && d.tabs.a && d.tabs.a.sadTab && !d.tabs.a.sadTab.hidden));`);
          await run(`ac.pageState.setState((s) => ({ popover: { ...s.popover, a: null } })); return true;`);
          if (!kept) throw new Error("an unrelated pane overlay publish took the native sad tab down");
          await untilSnapshot("the sad tab survives a zoom publish", (state) => nativeSad(state)?.visible && nativeSad(state)?.mode === name);
          await sleep(300);
        }
        const got = await frames(nativeShell, i);
        if (nativeShell && got.mode !== name) throw new Error(`native mode ${got.mode}`);
        if (nativeShell) {
          const sad = nativeSad(await untilSnapshot(`native ${name} sad tab`, (state) => nativeSad(state)?.visible && nativeSad(state)?.mode === name));
          if (!near(nativeFrame(sad.frame), got.overlay)) throw new Error(`native sad tab ${JSON.stringify(sad.frame)}, JS ${got.overlay}`);
          for (const title of labels[i]) {
            const control = sad.controls.find((item) => item.id === title);
            if (!control || !near(nativeFrame(control.frame), got.controls[title])) throw new Error(`native ${title} ${JSON.stringify(control)}, JS ${got.controls[title]}`);
          }
        }
        measured[tag][i] = got;
        const action = i === 0 ? "Reload" : "Wait";
        await run(`return click(${number}, ${JSON.stringify(centre(got.controls[action]))}).then(() => true);`);
        await until(`${action} clears it`, `const p = page(); return !p.crashed && !p.unresponsive || null;`, 3000);
        if (nativeShell) {
          await until("the native overlay goes", `return native().then((d) => !d || (!d.tabs.a && !d.inCard) || null);`, 3000);
          await untilSnapshot("the sad tab leaves the native snapshot", (state) => !nativeSad(state)?.visible);
        }
        if (pooled && i === 1) await until("the native model clears the hang", `return native().then((d) => !d || !d.tabs.a || !d.tabs.a.sadTab || d.tabs.a.sadTab.hidden || null);`, 3000);
        if (pooled && i === 0) await until("the pooled page reloads to A", `return ac.webviews.get("a") && ac.store.getState().tabs.a?.title === "A" && !ac.store.getState().live.a?.isLoading ? true : null;`, 8000);
        return got;
      });
    }
    if (prompts) {
      await rep.check(`${tag}-moves-with-its-tab`, async () => {
        await run(`ac.webviews.get("a").loadUrl("chrome://crash"); return true;`);
        await until("the crash reaches the store, once the hang's busy loop ends", `return page().crashed || null;`, 45000);
        await until("the sad tab in w1", `return sadIn("w1") || null;`, 5000);
        await run(`ac.store.getState().newTab("w1"); return true;`);
        const to = await run(`return ac.store.getState().moveTabsToWindow(["a"], null) ?? null;`);
        if (!to) throw new Error("no new window");
        await until("the sad tab leaves w1", `return sadIn("w1").then((s) => !s || null);`, 5000);
        await untilSnapshot("the sad tab leaves w1 in the native snapshot", (state) => !nativeSad(state)?.visible);
        await sleep(600);
        const crashedThere = await run(`return !!page().crashed;`);
        if (!crashedThere) {
          if (await run(`return sadIn(${JSON.stringify(to)});`)) throw new Error("the move recovered the page but the new window still draws a sad tab");
          return { to, reloadedOnMove: true };
        }
        await until("and shows in the new window", `return sadIn(${JSON.stringify(to)}) || null;`, 5000);
        await untilSnapshot("the sad tab follows the native window", (state) => nativeSad(state, to)?.visible);
        await run(`ac.webviews.get("a").reload(); return true;`);
        await until("a reload clears it there", `return sadIn(${JSON.stringify(to)}).then((s) => !s || null);`, 8000);
        return { to };
      });
    }
    await app.quit();
    app = null;
  }

  for (const [i] of modes.entries()) for (const tag of LEGS.map((l) => l.tag).filter((t) => t !== "rn")) {
    await rep.check(`${tag}-matches-rn-${i === 0 ? "crashed" : "unresponsive"}`, async () => {
      const rn = measured.rn[i];
      const nat = measured[tag][i];
      if (!rn || !nat) throw new Error("a mode was not measured");
      if (!near(nat.overlay, rn.overlay)) throw new Error(`overlay ${nat.overlay}, RN ${rn.overlay}`);
      for (const title of labels[i]) if (!near(nat.controls[title], rn.controls[title])) throw new Error(`${title} ${nat.controls[title]}, RN ${rn.controls[title]}`);
      return { overlay: rn.overlay, controls: rn.controls };
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

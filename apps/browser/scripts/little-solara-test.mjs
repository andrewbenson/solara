import { mkdtempSync, rmSync } from "node:fs";
import { sidebarSession, assertSidebarPosition } from "./sidebar-position-test.mjs";
import { createServer } from "node:http";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { launch, reporter, session, sleep } from "../../../scripts/lib/instance.mjs";
import { fixturePage } from "../../../scripts/lib/fixture-html.mjs";

const args = process.argv.slice(2);
const appArg = args.find((a) => !a.startsWith("--"));
if (!appArg || args.some((arg) => arg.startsWith("--") && arg !== "--keep-data")) {
  console.error(`usage: node little-solara-test.mjs <Debug Solara.app> [--keep-data]

Little Solara on a local page: the window opens with its bar and card where SmallChrome puts them (field at 84, 5,
28 high, the buttons at the right, the card inset 6 below a 38 pt bar), a click on the field opens the command panel,
the panel grows from the field box to RN's dropdown frame (left and top of the field, max(350, field + 137) wide, 12
from the window's right edge at most) with its field taking a click inside the 38 pt bar and a click on the card closing it,
a click on the bar's blank part leaves the window alone, and Open in Solara moves the tab to the main window and closes the small one;
then a relaunch handed a link, as another app hands it (SOLARA_ACCEPT_EXTERNAL_URLS=1, since a hidden instance otherwise
passes outside links on to another copy), opens it in Little Solara and not the main window, through the early link window
(the Debug-only engineInfo().earlyLinkWindow says "shown", not the reason it was skipped). The window is the native Little Solara shell:
its native backdrop and bar sit below the page and overlay slots.`);
  process.exit(2);
}
const keep = args.includes("--keep-data");
const scratch = mkdtempSync(join(tmpdir(), "ac-little-solara-"));
const data = join(scratch, "data");
const rep = reporter(join(scratch, "little-solara-test.log"), { name: "little-solara-test" });

const server = createServer((req, res) => {
  const name = req.url.slice(1) || "root";
  res.writeHead(200, { "content-type": "text/html" });
  res.end(fixturePage(name));
});
await new Promise((r) => server.listen(0, "127.0.0.1", r));
const url = (name) => `http://127.0.0.1:${server.address().port}/${name}`;
const fixture = session(sidebarSession({
  windows: [{ id: "w1", frame: [80, 80, 1280, 800], activeTabIds: { default: "a" } }],
  tabs: [{ id: "a", url: url("a"), title: "A" }],
  settings: { warnBeforeClosingLastTab: false, warnBeforeClosingWindow: false, searchSuggestions: false },
}));

const HELPERS = `
const C = globalThis.expo.modules.SolaraCEF;
const M = globalThis.expo.modules.SolaraMedia;
const st = () => ac.store.getState();
const settle = (ms) => new Promise((r) => setTimeout(r, ms));
const small = () => Object.values(st().windows).find((w) => w.kind === "small") || null;
const win = (n) => C.chromeWindows().then((ws) => ws.find((w) => w.window === n));
const act = (n, a) => C.devWindow(n, a);
const centre = (f) => [Math.round(f[0] + f[2] / 2), Math.round(f[1] + f[3] / 2)];
const click = (id, n, p) => ac.shell.devSetPointer(id, { x: p[0], y: p[1] }).then(() => act(n, "mouse:moved:" + p[0] + "," + p[1])).then(() => settle(60))
  .then(() => act(n, "mouse:down:" + p[0] + "," + p[1])).then(() => settle(60)).then(() => act(n, "mouse:up:" + p[0] + "," + p[1]));
const bar = (id) => M ? M.probe("littleSolara.bar", id).then(JSON.parse).then((rows) => rows[0] || null) : Promise.resolve(null);
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
const centre = (f) => [Math.round(f[0] + f[2] / 2), Math.round(f[1] + f[3] / 2)];
const untilSnapshot = async (what, accept, ms = 5000) => {
  const end = Date.now() + ms;
  let last;
  while (Date.now() < end) {
    last = await app.snapshot().catch((error) => ({ error: error.message }));
    if (!last.error && last.consistent && accept(last)) return last;
    await sleep(100);
  }
  throw new Error(`${what}: native snapshot never matched (${JSON.stringify(last)})`);
};
const bar = (id) => run(`return bar(${JSON.stringify(id)});`);
const near = (a, b) => a && b && a.length === b.length && a.every((v, i) => Math.abs(v - b[i]) <= 0.5);

let little = null;
try {
  app = await launch(resolve(appArg), {
    data, fresh: true, session: fixture, onboarded: true, probe: true,
    ready: "return !!ac.store.getState().windows.w1",
  });

  await assertSidebarPosition(app);

  await rep.check("opens", async () => {
    const before = await run(`return C.chromeWindows().then((ws) => ws.map((w) => w.window));`);
    await run(`ac.runCommand({ command: "newLittleSolara" }); return true;`);
    const id = await until("a Little Solara window", `return small()?.id ?? null;`);
    const tab = await until("its tab", `return st().windows[${JSON.stringify(id)}]?.tabIds[0] ?? null;`);
    await run(`st().navigate(${JSON.stringify(tab)}, ${JSON.stringify(url("b"))}, { userInitiated: true }); return true;`);
    await until("page B", `return st().tabs[${JSON.stringify(tab)}]?.title === "B" && !st().windowUi[${JSON.stringify(id)}]?.panel.open ? true : (st().windowUi[${JSON.stringify(id)}]?.panel.open && st().closePanel(${JSON.stringify(id)}), null);`, 15000);
    const number = await until("its window", `return C.chromeWindows().then((ws) => ws.find((w) => !${JSON.stringify(before)}.includes(w.window) && w.visible)?.window ?? null);`);
    const frame = await run(`return win(${number}).then((w) => w.frame);`);
    const [, , w, h] = frame.match(/[-\d.]+/g).map(Number);
    little = { id, tab, number, width: w, height: h };
    const nativeWindow = await untilSnapshot("native Little Solara window", (state) => state.windows.some((entry) => entry.id === id && entry.kind === "small" && entry.tabIds.includes(tab)) && state.tabs.some((entry) => entry.id === tab && entry.url === url("b")));
    const frameSize = nativeWindow.windows.find((entry) => entry.id === id)?.frame;
    if (Math.abs(frameSize.width - w) > 0.5 || Math.abs(frameSize.height - h) > 0.5) throw new Error(`native little window ${JSON.stringify(frameSize)}, JS ${w}x${h}`);
    return little;
  });

  await rep.check("shell", async () => {
    const active = await run(`return !!M && !!M.littleActive && M.littleActive(${JSON.stringify(little.id)});`);
    if (!active) throw new Error("the native Little Solara shell is inactive");

    const info = await until("the shell's bar", `return M.describeLittle(${JSON.stringify(little.id)}).then(JSON.parse).then((d) => d && d.barShown && d.backdrop ? d : null);`);
    const slots = info.slots.map(([slot]) => slot).join(",");
    if (slots !== "backdrop,bar,react,overlay") throw new Error(`slots ${slots}`);
    const [, , w, h] = info.bounds;
    if (!near(info.card, [6, 38, w - 12, h - 44])) throw new Error(`card ${info.card} in ${info.bounds}`);
    if (!near(info.bar, [0, 0, w, 38])) throw new Error(`bar ${info.bar}`);
    if (info.blankBarHit !== "SolaraUI.LittleSolaraDragStrip") throw new Error(`a click on the bar's blank part reaches ${info.blankBarHit}, not the drag strip`);
    if (info.reactFill !== null) throw new Error(`the RN root keeps its fill over the backdrop and bar: ${info.reactFill}`);
    const bars = await run(`return ["ShellLittleSolaraBar", "LittleSolaraBar", "NativePanelHost"].flatMap((name) => acPerf.findFibers(name, 20)).filter((fiber) => { for (let parent = fiber; parent; parent = parent.return) if (parent.type?.name === "LittleSolaraWindow") return true; return false; }).length;`);
    if (bars) throw new Error(`Little Solara still mounts ${bars} JS bar or panel producers`);
    return { slots, card: info.card, bounds: info.bounds, blankBarHit: info.blankBarHit };
  });

  await rep.check("native-card-fill", async () => {
    const original = await run(`return st().settings.appearance;`);
    const evidence = [];
    const page = await app.page((target) => target.url === url("b"), { timeout: 3000 });
    try {
      await page.eval('globalThis.smallWindowCardReceipt = "same-page"', { timeout: 3000 });
      for (const [appearance, fill] of [["light", "rgba(255,255,255,0.7)"], ["dark", "rgba(18,18,18,0.5)"]]) {
        await run(`st().updateSettings({ appearance: ${JSON.stringify(appearance)} }); return true;`);
        const card = await until(`${appearance} native card fill`, `return globalThis.expo.modules.SolaraHosted.devSmallWindowCards(${JSON.stringify(little.id)}).then(JSON.parse).then((entries) => entries.find((entry) => entry.tabId === ${JSON.stringify(little.tab)} && entry.fill === ${JSON.stringify(fill)}) ?? null);`);
        const shell = await run(`return M.describeLittle(${JSON.stringify(little.id)}).then(JSON.parse);`);
        if (!near(card.frame, shell.card) || card.radius !== 10) throw new Error(`native card geometry ${JSON.stringify(card)}, shell ${JSON.stringify(shell.card)}`);
        if (card.interceptsInput || card.focusable || card.accessibilityElement) throw new Error(`the card decoration claims interaction: ${JSON.stringify(card)}`);
        if (!card.pageHosted || !card.clipsPage || card.pageRadius !== 10 || card.contentCount < 1 || !card.owner.endsWith("SmallWindowPageHost")) throw new Error(`native page host missing: ${JSON.stringify(card)}`);
        const rn = await run(`const card = acPerf.findFibers("SmallWindowCard", 20).find((f) => f.memoizedProps.tabId === ${JSON.stringify(little.tab)});
          const style = card?.memoizedProps?.style;
          return { found: !!card, nativeSmall: card?.memoizedProps.nativeSmall, fill: style?.backgroundColor ?? null, radius: style?.borderRadius ?? null, clip: style?.overflow ?? null };`);
        if (!rn.found || !rn.nativeSmall || rn.fill !== null || rn.radius !== null || rn.clip !== null) throw new Error(`RN still paints or clips the small-window card: ${JSON.stringify(rn)}`);
        if (await page.eval('globalThis.smallWindowCardReceipt', { timeout: 3000 }) !== "same-page") throw new Error("changing the card fill replaced the page");
        const path = join(scratch, `little-card-${appearance}.png`);
        if (!await run(`return ac.shell.devSnapshotWindow(${JSON.stringify(little.id)}, ${JSON.stringify(path)});`)) throw new Error(`failed to capture ${appearance} card`);
        evidence.push({ appearance, card, rn, path });
      }
      return evidence;
    } finally {
      await run(`st().updateSettings({ appearance: ${JSON.stringify(original)} }); return true;`);
      page.close();
    }
  });

  const fieldRect = async () => {
    return (await until("native bar frames", `return bar(${JSON.stringify(little.id)}).then((r) => r && r.frames.field ? r.frames : null);`)).field;
  };

  await rep.check("bar-layout", async () => {
    const field = await fieldRect();
    const want = [84, 5, little.width - 84 - (6 + 2 * 28 + 2 + 6), 28];
    if (!near(field, want)) throw new Error(`field ${field}, SmallChrome puts it at ${want}`);
    const frames = (await bar(little.id)).frames;
    if (!near(frames.open, [little.width - 6 - 28, 5, 28, 28]) || !near(frames.copy, [little.width - 6 - 58, 5, 28, 28])) throw new Error(`buttons ${JSON.stringify(frames)}`);
    return { field };
  });

  await rep.check("field-opens-panel", async () => {
    const field = await fieldRect();
    await run(`return click(${JSON.stringify(little.id)}, ${little.number}, ${JSON.stringify(centre(field))}).then(() => true);`);
    await until("command panel open", `return st().windowUi[${JSON.stringify(little.id)}]?.panel.open || null;`, 3000);
    await run(`st().closePanel(${JSON.stringify(little.id)}); return true;`);
    await until("command panel closed", `return !st().windowUi[${JSON.stringify(little.id)}]?.panel.open || null;`, 3000);
    return true;
  });

  await rep.check("panel-frame-and-hits", async () => {
    const field = await fieldRect();
    const id = JSON.stringify(little.id);
    await run(`st().openPanel(${id}, st().tabs[${JSON.stringify(little.tab)}].url); return true;`);
    const grow = await until("the native panel", `return M.describeLittle(${id}).then(JSON.parse).then((shell) => shell?.panel);`, 3000);
    if (grow.variant !== "sidebar") throw new Error(`the native panel's variant is ${grow.variant}, expected sidebar`);
    const width = Math.min(Math.max(350, field[2] + 137), little.width - field[0] - 12);
    const from = grow.from;
    if (!near(from, field)) throw new Error(`grows from ${from}, the field is at ${field}`);
    if (!near(grow.frame, [field[0], field[1], width]) || grow.radius !== 12) throw new Error(`panel ${JSON.stringify(grow)}, expected ${[field[0], field[1], width]} radius 12`);
    await run(`return click(${id}, ${little.number}, [${Math.round(field[0] + width / 2)}, 19]).then(() => settle(300)).then(() => true);`);
    if (!(await run(`return !!st().windowUi[${id}]?.panel.open;`))) throw new Error("a click on the panel's field inside the bar closed the panel");
    await run(`return click(${id}, ${little.number}, [${Math.round(little.width / 2)}, ${Math.round(little.height - 40)}]).then(() => settle(300)).then(() => true);`);
    if (await run(`return !!st().windowUi[${id}]?.panel.open;`)) throw new Error("a click on the card left the panel open");
    return { from, frame: grow.frame, radius: grow.radius };
  });

  await rep.check("blank-bar-click", async () => {
    await run(`return click(${JSON.stringify(little.id)}, ${little.number}, [60, 19]).then(() => settle(300)).then(() => true);`);
    const state = await run(`return { open: !!st().windowUi[${JSON.stringify(little.id)}]?.panel.open, alive: !!st().windows[${JSON.stringify(little.id)}] };`);
    if (state.open || !state.alive) throw new Error(JSON.stringify(state));
    return state;
  });

  await rep.check("open-in-main", async () => {
    const frames = (await bar(little.id)).frames;
    await run(`return click(${JSON.stringify(little.id)}, ${little.number}, ${JSON.stringify(centre(frames.open))}).then(() => true);`);
    await until("the small window closes", `return !st().windows[${JSON.stringify(little.id)}] || null;`, 5000);
    const moved = await until("the tab in the main window", `return st().windows.w1.tabIds.includes(${JSON.stringify(little.tab)}) || null;`, 5000);
    await untilSnapshot("native tab moved to main", (state) => !state.windows.some((entry) => entry.id === little.id) && state.windows.some((entry) => entry.id === "w1" && entry.tabIds.includes(little.tab)) && state.tabs.some((entry) => entry.id === little.tab && entry.windowId === "w1"));
    return { moved };
  });


  await rep.check("close-clears-overlays-without-pausing-or-keying-main", async () => {
    const page = await app.page((target) => target.url === url("b"), { timeout: 3000 });
    const keyWindows = () => run(`return C.chromeWindows().then((windows) => windows.filter((w) => w.key).map((w) => w.window));`);
    const numberBefore = await run(`return C.chromeWindows().then((windows) => windows.map((w) => w.window));`);
    try {
      await page.eval(`(async () => {
        const canvas = document.createElement("canvas");
        canvas.width = 640;
        canvas.height = 360;
        const context = canvas.getContext("2d");
        const video = document.createElement("video");
        video.muted = true;
        video.playsInline = true;
        video.srcObject = canvas.captureStream(10);
        document.body.append(video);
        globalThis.closeTestVideo = video;
        globalThis.closeTestPauses = 0;
        video.addEventListener("pause", () => globalThis.closeTestPauses++);
        globalThis.closeTestTimer = setInterval(() => context.fillRect(0, 0, Math.random() * 120, 40), 50);
        await video.play();
        await video.requestPictureInPicture();
        return true;
      })()`, { userGesture: true, timeout: 5000 });
      await run(`ac.runCommand({ command: "newLittleSolara" }); return true;`);
      const id = await until("replacement small window", `return small()?.id ?? null;`);
      const windowId = JSON.stringify(id);
      const number = await until("visible small window", `return C.chromeWindows().then((windows) => windows.find((w) => w.visible && !${JSON.stringify(numberBefore)}.includes(w.window))?.window ?? null);`);
      await run(`st().openPanel(${windowId}, "queued"); return true;`);
      const before = await page.eval("({ time: globalThis.closeTestVideo.currentTime, pauses: globalThis.closeTestPauses })");
      const priorKeys = await keyWindows();
      if (!priorKeys.includes(number)) throw new Error("Little Solara must be key before closing");
      await run(`return act(${number}, "close-button");`);
      await until("closed small window and native overlay registry", `return M.describeLittle(${windowId}).then(JSON.parse).then((shell) => !shell && !M.littleActive(${windowId}) && !st().windows[${windowId}] ? true : null);`, 5000);
      await sleep(300);
      const after = await page.eval("({ time: globalThis.closeTestVideo.currentTime, pauses: globalThis.closeTestPauses, paused: globalThis.closeTestVideo.paused, pip: document.pictureInPictureElement === globalThis.closeTestVideo })");
      if (!after.pip || after.paused || after.pauses !== before.pauses || after.time <= before.time) throw new Error(`playback stopped at ${JSON.stringify(after)}, before close ${JSON.stringify(before)}`);
      if ((await keyWindows()).some((key) => key !== number && !priorKeys.includes(key))) throw new Error("closing Little Solara keyed another window");
      if (await run(`return !!small() || M.littleActive(${windowId});`)) throw new Error("Little Solara reopened after close");
      return { before: before.time, after: after.time, pauses: after.pauses - before.pauses, pip: after.pip, priorKeys };
    } finally {
      await page.eval("(async () => { if (document.pictureInPictureElement) await document.exitPictureInPicture(); clearInterval(globalThis.closeTestTimer); globalThis.closeTestVideo?.srcObject?.getTracks().forEach((track) => track.stop()); globalThis.closeTestVideo?.remove(); return true; })()").catch(() => {});
      page.close();
    }
  });

  await rep.check("link-from-another-app", async () => {
    const outcomes = [];
    for (;;) {
      await sleep(1500);
      await app.quit();
      app = null;
      app = await launch(resolve(appArg), {
        data, probe: true, urls: [url("c")],
        env: { SOLARA_ACCEPT_EXTERNAL_URLS: "1" },
        ready: "return !!ac.store.getState().windows.w1",
      });
      outcomes.push(await run(`return C.engineInfo().then((i) => i.earlyLinkWindow ?? null);`));
      if (outcomes.at(-1) !== "jsRoutedFirst" || outcomes.length === 3) break;
      await until("the link's window before relaunching", `return small()?.id ?? null;`, 15000);
    }
    const id = await until("Little Solara for the link", `return small()?.id ?? null;`, 15000);
    const tab = await until("page C in it", `const t = st().tabs[st().windows[${JSON.stringify(id)}]?.tabIds[0]]; return t && t.title === "C" ? t.id : null;`, 15000);
    const main = await run(`return st().windows.w1.tabIds.map((t) => st().tabs[t].url);`);
    if (main.includes(url("c"))) throw new Error(`the link opened in the main window too: ${main}`);
    const active = await run(`return !!M && !!M.littleActive && M.littleActive(${JSON.stringify(id)});`);
    if (!active) throw new Error("the native Little Solara shell is inactive");
    const early = outcomes.at(-1);
    if (early !== "shown") throw new Error(`the early link window's outcomes were ${outcomes.join(", ")}, so the JS path opened this window, not the early one`);
    const shell = await until("the shell's bar", `return M.describeLittle(${JSON.stringify(id)}).then(JSON.parse).then((d) => d && d.barShown && d.blankBarHit === "SolaraUI.LittleSolaraDragStrip" ? d : null);`);
    return { id, tab, early, outcomes, slots: shell?.slots.map(([slot]) => slot) };
  });
  const relaunchWithLink = async (env) => {
    await sleep(1500);
    await app.quit();
    app = null;
    app = await launch(resolve(appArg), {
      data, probe: true, urls: [url("c")],
      env: { SOLARA_ACCEPT_EXTERNAL_URLS: "1", ...env },
      ready: "return !!ac.store.getState().windows.w1",
    });
    const id = await until("Little Solara for the link", `return small()?.id ?? null;`, 15000);
    await until("page C in it", `const t = st().tabs[st().windows[${JSON.stringify(id)}]?.tabIds[0]]; return t && t.title === "C" ? t.id : null;`, 15000);
    await sleep(2000);
    const windows = await run(`return Object.values(st().windows).filter((w) => w.kind === "small").map((w) => w.id);`);
    if (windows.length !== 1) throw new Error(`${windows.length} Little Solara windows for one link: ${windows}`);
    const main = await run(`return st().windows.w1.tabIds.map((t) => st().tabs[t].url);`);
    if (main.includes(url("c"))) throw new Error(`the link opened in the main window too: ${main}`);
    const info = await run(`return C.engineInfo();`);
    if (info.unclaimedEarlyLinkWindows !== 0) throw new Error(`${info.unclaimedEarlyLinkWindows} early link window(s) left unclaimed beside Little Solara`);
    return { id, outcome: info.earlyLinkWindow };
  };

  await rep.check("link-when-js-starts-first", async () => {
    const result = await relaunchWithLink({ SOLARA_TEST_EARLY_LINK_AFTER_JS: "1" });
    if (result.outcome !== "shownAfterJS") throw new Error(`outcome ${result.outcome}, expected the early window shown after JS started`);
    return result;
  });

  await rep.check("link-when-the-early-window-fails", async () => {
    const result = await relaunchWithLink({ SOLARA_TEST_EARLY_LINK_FAILS: "1" });
    if (result.outcome !== "showFailed") throw new Error(`outcome ${result.outcome}, expected showFailed`);
    return result;
  });

  await rep.check("link-adopted-into-the-main-window-closes-the-early-window", async () => {
    await run(`st().updateSettings({ openLinksInLittleSolara: false }); return true;`);
    try {
      await sleep(1500);
      await app.quit();
      app = null;
      app = await launch(resolve(appArg), {
        data, probe: true, urls: [url("c")],
        env: { SOLARA_ACCEPT_EXTERNAL_URLS: "1", SOLARA_TEST_EARLY_LINK_IGNORE_SETTING: "1" },
        ready: "return !!ac.store.getState().windows.w1",
      });
      const tab = await until("page C loaded in the main window", `const id = st().windows.w1?.tabIds.find((t) => st().tabs[t]?.url === ${JSON.stringify(url("c"))}); return id && st().tabs[id].title === "C" ? id : null;`, 15000);
      const outcome = await run(`return C.engineInfo().then((i) => i.earlyLinkWindow ?? null);`);
      if (outcome !== "shown") throw new Error(`outcome ${outcome}, expected the early window shown before JS adopted the link`);
      await until("the early window closed", `return C.engineInfo().then((i) => i.unclaimedEarlyLinkWindows === 0 ? true : null);`, 1000);
      if (await run(`return !!small();`)) throw new Error("a Little Solara window opened for a link the main window took");
      await sleep(1000);
      const kept = await run(`return st().windows.w1.tabIds.includes(${JSON.stringify(tab)});`);
      if (!kept) throw new Error("page C's tab left the main window");
      const holders = await run(`return C.tabStrips().then((tx) => tx.strips.filter((s) => s.tabs.some((t) => t.key === ${JSON.stringify(tab)})).map((s) => s.appWindow ?? null));`);
      if (holders.length !== 1 || holders[0] !== "w1") throw new Error(`page C's tab is in the strips of ${JSON.stringify(holders)}, expected only w1's`);
      const page = await app.page((t) => t.url === url("c"), { timeout: 3000 });
      try {
        const sum = await page.eval("1 + 1", { timeout: 3000 });
        if (sum !== 2) throw new Error(`page C's renderer answered ${sum} to 1 + 1`);
        const title = await page.eval("document.title", { timeout: 3000 });
        if (title !== "C") throw new Error(`page C's renderer has the title ${title}`);
      } finally {
        page.close();
      }
      return { tab, outcome };
    } finally {
      if (app) await run(`st().updateSettings({ openLinksInLittleSolara: true }); return true;`).catch((e) => console.error(`could not turn openLinksInLittleSolara back on: ${e.message}`));
    }
  });
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

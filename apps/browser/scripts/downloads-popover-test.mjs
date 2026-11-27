import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { launch, reporter, session, sleep } from "../../../scripts/lib/instance.mjs";

const args = process.argv.slice(2);
const appArg = args.find((a) => !a.startsWith("--"));
if (!appArg) {
  console.error(`usage: node downloads-popover-test.mjs <Debug Solara.app> [--keep-data]

The native Downloads popover with and without the window shell. Checks button placement,
card and list geometry, hover stability, View all downloads, click-away dismissal and Clear.`);
  process.exit(2);
}
const keep = args.includes("--keep-data");
const out = args.includes("--out") ? resolve(args[args.indexOf("--out") + 1]) : null;
if (out) mkdirSync(out, { recursive: true });
const scratch = mkdtempSync(join(tmpdir(), "ac-downloads-popover-"));
const rep = reporter(join(scratch, "downloads-popover-test.log"), { name: "downloads-popover-test" });
const files = ["one.zip", "two.pdf"].map((name) => {
  const path = join(scratch, name);
  writeFileSync(path, "x".repeat(10));
  return path;
});
const fixture = session({
  windows: [{ id: "w1", frame: [80, 80, 1280, 800], activeTabIds: { default: "a" } }],
  tabs: [{ id: "a", url: "about:blank", title: "BLANK" }],
  settings: { warnBeforeClosingLastTab: false, warnBeforeClosingWindow: false },
});

const HELPERS = `
const C = globalThis.expo.modules.SolaraCEF;
const M = globalThis.expo.modules.SolaraMedia;
const st = () => ac.store.getState();
const settle = (ms) => new Promise((r) => setTimeout(r, ms));
const click = (n, p) => C.devWindow(n, "mouse:moved:" + p[0] + "," + p[1]).then(() => settle(60))
  .then(() => C.devWindow(n, "mouse:down:" + p[0] + "," + p[1])).then(() => settle(60)).then(() => C.devWindow(n, "mouse:up:" + p[0] + "," + p[1]));
const native = () => M && M.describeDownloadsPanel ? M.describeDownloadsPanel("w1").then(JSON.parse) : Promise.resolve(null);
`;
let app = null;
const run = (body, timeout = 20000) => app.eval(`${HELPERS}\n${body}`, { timeout });
const until = async (what, body, ms = 8000) => {
  const end = Date.now() + ms;
  let last;
  while (Date.now() < end) {
    last = await run(body).catch((e) => ({ error: String(e.message ?? e) }));
    if (last && !last.error) return last;
    await sleep(100);
  }
  throw new Error(`${what}: never true (last ${JSON.stringify(last)})`);
};
const nativeFrame = (frame) => frame && [frame.x, frame.y, frame.width, frame.height];
const untilSnapshot = async (what, accept, ms = 5000) => {
  const deadline = Date.now() + ms;
  let last;
  while (Date.now() < deadline) {
    last = await app.snapshot().catch((e) => ({ error: e.message }));
    if (!last.error && accept(last)) return last;
    await sleep(100);
  }
  throw new Error(`${what}: native snapshot never matched (${JSON.stringify(last)})`);
};
const near = (a, b) => a && b && a.length === b.length && a.every((v, i) => Math.abs(v - b[i]) <= 0.5);
const centre = (f) => [Math.round(f[0] + f[2] / 2), Math.round(f[1] + f[3] / 2)];
const seed = files.map((path, i) => ({ id: `dl-${i}`, url: `https://example.com/${i}`, filename: path.split("/").pop(), path, state: "finished", paused: false, received: 10, total: 10, speed: 0, mimeType: "application/zip" }));
const got = {};

const expected = (root, p, list) => {
  const arrowRoom = p.arrow === "none" ? 0 : 9;
  const height = list + arrowRoom;
  const y = p.bottom !== undefined ? root[1] + root[3] - p.bottom - height : root[1] + p.top;
  return [root[0] + p.left, y, p.width, height];
};

try {
  for (const nativeShell of [false, true]) {
    const tag = nativeShell ? "shell" : "inline";
    app = await launch(resolve(appArg), {
      data: join(scratch, `data-${tag}`), fresh: true, session: fixture, onboarded: true, probe: true,
      env: { SOLARA_NATIVE_SHELL: nativeShell ? "1" : "0" },
      ready: "return !!ac.store.getState().windows.w1",
    });
    const number = await until("the window", `return C.chromeWindows().then((ws) => ws.find((w) => w.visible)?.window ?? null);`, 15000);
    const open = () => run(`${JSON.stringify(seed)}.forEach((d) => st().upsertDownload(d)); st().setDownloadsOpen("w1", true); return true;`);
    const shown = () => until("the native card", `return native().then((d) => d?.card && d.opacity === 1 ? d : null);`, 4000);

    if (!nativeShell) await rep.check("inline-downloads-button", async () => {
      await open();
      const { button } = await shown();
      if (!button) throw new Error("the native panel has no Downloads button anchor");
      await run(`st().setDownloadsOpen("w1", false); return settle(300).then(() => true);`);
      await run(`return click(${number}, ${JSON.stringify(centre(button))}).then(() => true);`);
      await shown();
      await run(`st().setDownloadsOpen("w1", false); return settle(250).then(() => true);`);
      return { button };
    });

    for (const addressBar of ["toolbar", "sidebar"]) await rep.check(`${tag}-frame-${addressBar}`, async () => {
      await run(`st().updateSettings({ addressBar: ${JSON.stringify(addressBar)} }); return settle(600).then(() => true);`);
      await open();
      const d = await shown();
      const { placement: p, root, card, button } = d;
      const list = d.list[3];
      const shifts = JSON.parse(await run(`return globalThis.expo.modules.SolaraDownloads.devHoverShifts();`));
      if (!shifts.hosts || !shifts.hovered || shifts.shifts.length) throw new Error(`hover shifts in the native list: ${JSON.stringify(shifts)}`);
      const snapshot = await untilSnapshot("native downloads card", (state) => state.windows.some((w) => w.id === "w1" && w.overlays.some((o) => o.kind === "downloads" && o.opacity === 1)));
      const overlay = snapshot.windows.find((w) => w.id === "w1")?.overlays.find((o) => o.kind === "downloads");
      if (!overlay.visible || !near(nativeFrame(overlay.frame), d.card) || !near(nativeFrame(overlay.list), d.list) ||
        ["View all downloads", "Clear"].some((id) => d.controls[id] && !overlay.controls.some((c) => c.id === id && near(nativeFrame(c.frame), d.controls[id]))) ||
        snapshot.downloads.finished !== 2) throw new Error(`native downloads ${JSON.stringify(overlay)} vs ${JSON.stringify(d)}`);
      if (!button || Math.abs(root[0] + p.left + p.arrowX - button[0] - button[2] / 2) > 0.5) {
        throw new Error(`the arrow misses the button: ${JSON.stringify({ p, root, button })}`);
      }
      const gap = p.arrow === "bottom" ? button[1] - card[1] - card[3] : card[1] - button[1] - button[3];
      if (Math.abs(gap - 1) > 0.5) throw new Error(`button-to-card gap ${gap} pt`);
      const want = expected(root, p, list);
      if (!near(card, want)) throw new Error(`card ${card}, want ${want} from ${JSON.stringify(p)} in ${root}`);
      if (addressBar === "sidebar" && p.bottom === undefined) throw new Error(`the panel opens downward with the address bar in the sidebar: ${JSON.stringify(p)}`);
      got[`${tag}-${addressBar}`] = { card, list, p, root };
      if (out) {
        const path = join(out, `${tag}-${addressBar}.png`);
        if (!await run(`return ac.shell.devSnapshotWindow("w1", ${JSON.stringify(path)});`)) throw new Error("snapshot failed");
        writeFileSync(join(out, `${tag}-${addressBar}.json`), JSON.stringify({ card, list, p, root }, null, 2));
      }
      await run(`st().setDownloadsOpen("w1", false); return settle(400).then(() => true);`);
      return { card, list, arrow: p.arrow, bottom: p.bottom };
    });
    await run(`st().updateSettings({ addressBar: "toolbar" }); return settle(600).then(() => true);`);

    await rep.check("native-gone-after-close", async () => {
      await until("the panel goes", `return native().then((d) => d === null || null);`, 3000);
      await untilSnapshot("native downloads closed", (state) => !state.windows.some((w) => w.overlays.some((o) => o.kind === "downloads" && o.visible)));
      return true;
    });

    await rep.check("native-view-all", async () => {
      await open();
      const d = await until("the card", `return native().then((d) => d && d.opacity === 1 && d.controls["View all downloads"] ? d : null);`, 4000);
      await run(`return click(${number}, ${JSON.stringify(centre(d.controls["View all downloads"]))}).then(() => true);`);
      const page = await until("the downloads page", `return Object.values(st().tabs).map((t) => t.url).find((u) => /downloads/.test(u)) || null;`, 5000);
      await until("the popover closes", `return !st().windowUi.w1?.downloadsOpen && native().then((d) => d === null || null);`, 3000);
      await untilSnapshot("native downloads page", (state) => state.tabs.some((t) => t.url && /downloads/.test(t.url)) &&
        !state.windows.some((w) => w.overlays.some((o) => o.kind === "downloads" && o.visible)));
      return { page };
    });

    await rep.check("native-click-away", async () => {
      await open();
      const d = await until("the card", `return native().then((d) => d && d.opacity === 1 ? d : null);`, 4000);
      const tabs = await run(`return st().windows.w1.tabIds.length;`);
      const away = [Math.round(d.card[0] + d.card[2] + 200), Math.round(d.card[1] + d.card[3] / 2)];
      await run(`return click(${number}, ${JSON.stringify(away)}).then(() => true);`);
      await until("the popover closes", `return !st().windowUi.w1?.downloadsOpen && native().then((d) => d === null || null);`, 3000);
      const after = await run(`return [st().windows.w1.tabIds.length, st().downloads.length];`);
      if (after[0] !== tabs || after[1] !== 2) throw new Error(`tabs ${tabs} -> ${after[0]}, downloads ${after[1]}`);
      const snapshot = await untilSnapshot("native downloads click-away", (state) => state.downloads.count === 2 &&
        !state.windows.some((w) => w.overlays.some((o) => o.kind === "downloads" && o.visible)));
      if (snapshot.windows.find((w) => w.id === "w1")?.tabIds.length !== after[0]) throw new Error(`native tab count ${JSON.stringify(snapshot.windows)}`);
      return { away };
    });

    await rep.check("native-clear", async () => {
      await open();
      const d = await until("the card", `return native().then((d) => d && d.opacity === 1 && d.controls.Clear ? d : null);`, 4000);
      await run(`return click(${number}, ${JSON.stringify(centre(d.controls.Clear))}).then(() => true);`);
      await until("the list empties", `return !st().windowUi.w1?.downloadsOpen && st().downloads.filter((x) => x.state === "finished").length === 0 || null;`, 3000);
      await until("the panel goes", `return native().then((d) => d === null || null);`, 3000);
      await untilSnapshot("native downloads cleared", (state) => state.downloads.finished === 0 &&
        !state.windows.some((w) => w.overlays.some((o) => o.kind === "downloads" && o.visible)));
      return true;
    });
    await app.quit();
    app = null;
  }
  await rep.check("shell-and-inline-match", async () => {
    const out = {};
    for (const addressBar of ["toolbar", "sidebar"]) {
      const inline = got[`inline-${addressBar}`];
      const shell = got[`shell-${addressBar}`];
      if (inline.list !== shell.list) throw new Error(`${addressBar}: list height native ${shell.list}, inline ${inline.list}`);
      const same = JSON.stringify(inline.p) === JSON.stringify(shell.p);
      if (same && !near(inline.card, shell.card)) throw new Error(`${addressBar}: card native ${shell.card}, inline ${inline.card}`);
      out[addressBar] = { samePlacement: same, inline: inline.card, shell: shell.card };
    }
    return out;
  });
} catch (e) {
  rep.record("run", { error: e });
} finally {
  await app?.quit().catch(() => {});
  if (!keep && rep.disposable) rmSync(scratch, { recursive: true, force: true });
}
const failed = rep.results.filter((r) => !r.ok);
console.log(`${rep.results.length - failed.length}/${rep.results.length} passed${failed.length ? `; log ${rep.logFile}` : ""}`);
process.exit(failed.length ? 1 : 0);

import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { launch, reporter, session, sleep } from "../../../scripts/lib/instance.mjs";

const args = process.argv.slice(2);
const appArg = args.find((a) => !a.startsWith("--"));
if (!appArg) {
  console.error(`usage: node update-pill-test.mjs <Debug Solara.app> [--keep-data]

"New Solara Version Available", with a pending update simulated by the Debug-only devSimulatePendingUpdate (no feed,
no Sparkle): the sidebar shows the pill above its footer and the tab list ends above it; a click on the pill asks the
updater to install; the app menu shows "Restart to Update" only while one is pending; with top tabs the pill sits in
the toolbar before the extension icons and a click installs; clearing the pending update removes every one of them;
and an install that quits goes through the normal quit, so the windows and tabs come back on the next launch.`);
  process.exit(2);
}
const keep = args.includes("--keep-data");
const scratch = mkdtempSync(join(tmpdir(), "ac-update-pill-"));
const rep = reporter(join(scratch, "update-pill-test.log"), { name: "update-pill-test" });
const fixture = session({
  profiles: [{ id: "default", name: "Personal" }, { id: "work", name: "Work" }],
  windows: [{ id: "w1", frame: [80, 80, 1280, 800], activeTabIds: { default: "a" } }],
  tabs: [{ id: "a", url: "about:blank", title: "A" }, { id: "b", url: "about:blank", title: "B" }],
  settings: { warnBeforeClosingLastTab: false, warnBeforeClosingWindow: false, warnBeforeQuitting: false },
});
const HELPERS = `
const C = globalThis.expo.modules.SolaraCEF;
const H = globalThis.expo.modules.SolaraHosted;
const A = globalThis.expo.modules.SolaraApp;
const st = () => ac.store.getState();
const settle = (ms) => new Promise((r) => setTimeout(r, ms));
const win = () => C.chromeWindows().then((ws) => ws.find((w) => w.hasRoot).window);
const act = (a) => win().then((n) => C.devWindow(n, a));
const col = () => H.sidebarShell("w1").then((d) => JSON.parse(d));
const click = (x, y) => act("mouse:down:" + x + "," + y + ",1").then(() => settle(30)).then(() => act("mouse:up:" + x + "," + y + ",1")).then(() => settle(150));
`;
let inst = null;
const run = (body, timeout = 30000) => inst.eval(`${HELPERS}\n${body}`, { timeout });
const until = async (what, body, accept, ms = 6000) => {
  const end = Date.now() + ms;
  let last;
  while (Date.now() < end) {
    last = await run(body).catch((e) => ({ error: e.message }));
    if (accept(last)) return last;
    await sleep(150);
  }
  throw new Error(`${what}: ${JSON.stringify(last)}`);
};
const env = { SOLARA_NATIVE_SHELL: "1", SOLARA_NATIVE_TOP_STRIP: "1" };

try {
  inst = await launch(resolve(appArg), { data: join(scratch, "data"), fresh: true, session: fixture, onboarded: true, env, ready: "return !!ac.store.getState().windows.w1" });
  await sleep(2500);
  const before = await run(`return col();`);
  if (!before?.chrome) throw new Error(`no native sidebar chrome: ${JSON.stringify(before)}`);

  await rep.check("(a) nothing shows while no update is pending", async () => {
    const out = await run(`return Promise.all([col(), A.devRestartToUpdateShown()]).then(([c, menu]) => ({ update: c.chrome.update, menu }));`);
    if (out.update !== null || out.menu !== false) throw new Error(JSON.stringify(out));
    return out;
  });

  await rep.check("(b) a pending update puts the pill above the footer and the list ends above it", async () => {
    await run(`return A.devSimulatePendingUpdate("9.9.9", "count");`);
    const c = await until("pill", `return col();`, (c) => c?.chrome?.update?.rect && c.bottom === before.bottom + 38);
    const [, y, w, h] = c.chrome.update.rect;
    const listBottom = c.list[1] + c.list[3];
    const out = { text: c.chrome.update.text, rect: c.chrome.update.rect, footer: c.chrome.footer, listBottom, pillTop: c.frame[1] + y, width: c.frame[2] };
    if (out.text !== "New Solara Version Available" || h !== 30 || w !== c.frame[2] - 16 || listBottom > out.pillTop + 0.5 || c.chrome.footer !== before.chrome.footer + 38)
      throw new Error(JSON.stringify(out));
    return out;
  });

  await rep.check("(c) the app menu offers Restart to Update while it is pending", async () => {
    const menu = await run(`return A.devRestartToUpdateShown();`);
    if (menu !== true) throw new Error(String(menu));
    return { menu };
  });

  await rep.check("(d) a click on the sidebar pill asks the updater to install", async () => {
    const c = await run(`return col();`);
    const [x, y, w, h] = c.chrome.update.rect;
    const at = [Math.round(c.frame[0] + x + w / 2), Math.round(c.frame[1] + y + h / 2)];
    const hit = await run(`return act("hit:${at[0]},${at[1]}");`);
    const count = await run(`return click(${at[0]}, ${at[1]}).then(() => A.devSimulatedInstallRequests());`);
    if (!/SidebarUpdatePill/.test(String(hit)) || count !== 1) throw new Error(JSON.stringify({ hit, count, at }));
    return { hit: String(hit).split("\n")[0], count };
  });

  await rep.check("(e) with top tabs the pill sits in the toolbar and a click installs", async () => {
    await run(`st().updateSettings({ tabLayout: "top" }); return settle(1500);`);
    const found = await until("toolbar pill", `const ys = [62, 58, 66, 21];
      const scan = (i, x) => i >= ys.length ? null : x <= 700 ? scan(i + 1, 1270)
        : act("hit:" + x + "," + ys[i]).then((h) => /SidebarUpdatePill/.test(String(h)) ? { x, y: ys[i], hit: String(h).split("\\n")[0] } : scan(i, x - 6));
      return scan(0, 1270);`, (r) => r && r.x, 15000);
    const y = found.y;
    const count = await run(`return click(${found.x}, ${y}).then(() => A.devSimulatedInstallRequests());`);
    await run(`st().updateSettings({ tabLayout: "sidebar" }); return settle(1500);`);
    if (count !== 2) throw new Error(JSON.stringify({ found, count }));
    return { ...found, count };
  });

  await rep.check("(f) clearing the pending update removes the pill and the menu item", async () => {
    await run(`return A.devSimulatePendingUpdate(null, "count");`);
    const c = await until("pill gone", `return col();`, (c) => c?.chrome && c.chrome.update === null && c.bottom === before.bottom);
    const menu = await run(`return A.devRestartToUpdateShown();`);
    if (menu !== false) throw new Error(String(menu));
    return { bottom: c.bottom, menu };
  });

  await rep.check("(g) an install that quits goes through the normal quit, and the session comes back", async () => {
    await run(`return A.devSimulatePendingUpdate("9.9.9", "quit");`);
    await until("pill back", `return col();`, (c) => c?.chrome?.update?.rect);
    const tabsBefore = await run(`return Object.keys(st().tabs).sort();`);
    await run(`setTimeout(() => A.installPendingUpdate(), 200); return true;`);
    const end = Date.now() + 20000;
    while (inst.alive && Date.now() < end) await sleep(250);
    const quitItself = !inst.alive;
    await inst.quit({ timeout: 5000 });
    if (!quitItself) throw new Error("the app didn't quit on the simulated install");
    inst = await launch(resolve(appArg), { data: join(scratch, "data"), onboarded: true, env, ready: "return !!Object.keys(ac.store.getState().windows).length" });
    await sleep(2500);
    const tabsAfter = await run(`return Object.keys(st().tabs).sort();`);
    if (JSON.stringify(tabsAfter) !== JSON.stringify(tabsBefore)) throw new Error(JSON.stringify({ tabsBefore, tabsAfter }));
    return { tabs: tabsAfter };
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

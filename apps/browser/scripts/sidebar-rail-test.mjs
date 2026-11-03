import { mkdtempSync, rmSync, statSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { launch, reporter, session, sleep } from "../../../scripts/lib/instance.mjs";

const args = process.argv.slice(2);
const appArg = args.find((a) => !a.startsWith("--"));
if (!appArg) {
  console.error(`usage: node sidebar-rail-test.mjs <Debug Solara.app> [--keep-data] [--shots <dir>]

The icons-only sidebar rail under the native shell. View › Icons-Only Sidebar (the toggleSidebarIconsOnly command)
narrows the native column to 84 pt and back to the saved full width, which the rail never overwrites; in the rail the
footer's downloads button and profile dots sit in separate bands inside the column, and a pending update shows as a
round 34 pt button inside it; Settings › Tabs' switch is the same setting. With --shots, snapshots the window in-process (devSnapshotWindow) in the
rail and at full width, dark and light, with a pending update, for the owner's visual check.`);
  process.exit(2);
}
const keep = args.includes("--keep-data");
const shotsAt = args.indexOf("--shots");
const shots = shotsAt >= 0 ? args[shotsAt + 1] : null;
const scratch = mkdtempSync(join(tmpdir(), "ac-sidebar-rail-"));
const rep = reporter(join(scratch, "sidebar-rail-test.log"), { name: "sidebar-rail-test" });
const fixture = session({
  profiles: [{ id: "default", name: "Personal" }, { id: "work", name: "Work" }],
  windows: [{ id: "w1", frame: [80, 80, 1280, 800], activeTabIds: { default: "a" } }],
  tabs: [{ id: "a", url: "about:blank", title: "A" }, { id: "b", url: "about:blank", title: "B" }, { id: "c", url: "about:blank", title: "C" }],
  settings: { warnBeforeClosingLastTab: false, warnBeforeClosingWindow: false, sidebarWidth: 240 },
});
const HELPERS = `
const C = globalThis.expo.modules.SolaraCEF;
const H = globalThis.expo.modules.SolaraHosted;
const A = globalThis.expo.modules.SolaraApp;
const st = () => ac.store.getState();
const col = () => H.sidebarShell("w1").then((d) => JSON.parse(d));
`;
let inst = null;
const run = (body, timeout = 15000) => inst.eval(`${HELPERS}\n${body}`, { timeout });
const until = async (what, probe, ms = 6000) => {
  const end = Date.now() + ms;
  let last;
  while (Date.now() < end) {
    last = await probe().catch((e) => ({ error: String(e.message ?? e) }));
    if (last && !last.error && last.ok) return last;
    await sleep(150);
  }
  throw new Error(`${what}: ${JSON.stringify(last)}`);
};
const column = () => run(`return col();`);
const widthIs = (w) => until(`the native column at ${w} pt`, async () => {
  const c = await column();
  return { ok: !!c && Math.round(c.frame[2]) === w, width: c?.frame?.[2] };
});
const toggle = () => run(`ac.runCommand({ command: "toggleSidebarIconsOnly", arg: null, windowId: "w1" }); return true;`);
const overlap = (a, b) => !!a && !!b && a[0] < b[0] + b[2] && b[0] < a[0] + a[2] && a[1] < b[1] + b[3] && b[1] < a[1] + a[3];
const inside = (r, width) => r[0] >= 0 && r[0] + r[2] <= width;
const capture = async (name) => {
  if (!shots) return null;
  const file = join(shots, `${name}.png`);
  const saved = await run(`return ac.shell.devSnapshotWindow("w1", ${JSON.stringify(file)});`);
  if (saved === false) throw new Error(`the window snapshot ${name} failed`);
  return `${Math.round(statSync(file).size / 1024)} KB`;
};

try {
  inst = await launch(appArg, { data: join(scratch, "data"), session: fixture, env: { SOLARA_NATIVE_SHELL: "1", SOLARA_NATIVE_TOP_STRIP: "1" }, ready: "return !!ac.store" });
  rep.log(`instance: pid ${inst.pid}, DevTools port ${inst.port}`);

  await rep.check("the native build offers the rail", async () => {
    if ((await run(`return A.sidebarRail === true;`)) !== true) throw new Error("SolaraApp.sidebarRail isn't true");
    return { supported: true };
  });

  await rep.check("the full-width column starts at the saved width", async () => {
    const c = await widthIs(240);
    return { width: c.width, shot: await capture("full-dark") };
  });

  await rep.check("View › Icons-Only Sidebar narrows the column to 84 pt and keeps the saved width", async () => {
    await toggle();
    const c = await widthIs(84);
    const s = await run(`return { iconsOnly: st().settings.sidebarIconsOnly, width: st().settings.sidebarWidth };`);
    if (!s.iconsOnly || s.width !== 240) throw new Error(`settings after entering the rail: ${JSON.stringify(s)}`);
    return { width: c.width, settings: s };
  });

  await rep.check("in the rail the footer's downloads button and profile dots don't overlap and stay inside the column", async () => {
    await run(`st().upsertDownload({ id: "d1", url: "https://example.com/a.pdf", filename: "a.pdf", path: "/tmp/a.pdf", state: "finished", paused: false, received: 1, total: 1, speed: 0, mimeType: "application/pdf" }); st().setDownloadsOpen("w1", false); return true;`);
    const got = await until("the footer's downloads button and dots", async () => {
      const c = await column();
      const chrome = c?.chrome;
      return { ok: !!chrome?.footerDownloads && chrome.dots.length === 2, chrome, width: c?.frame?.[2] };
    });
    const dots = got.chrome.dots.map((d) => d.rect);
    const downloads = got.chrome.footerDownloads;
    if (dots.some((d) => overlap(d, downloads))) throw new Error(`a profile dot overlaps downloads: ${JSON.stringify({ dots, downloads })}`);
    if (![...dots, downloads].every((r) => inside(r, got.width))) throw new Error(`a footer control leaves the 84 pt column: ${JSON.stringify({ dots, downloads })}`);
    return { dots, downloads, shot: await capture("rail-dark") };
  });

  await rep.check("a pending update shows as a round 34 pt button inside the rail", async () => {
    await run(`return A.devSimulatePendingUpdate("9.9.9", "count");`);
    try {
      const got = await until("the rail update button", async () => {
        const c = await column();
        const u = c?.chrome?.update;
        return { ok: !!u && Math.round(u.rect[2]) === 34 && Math.round(u.rect[3]) === 34, update: u, width: c?.frame?.[2] };
      });
      if (!inside(got.update.rect, got.width)) throw new Error(`the update button leaves the column: ${JSON.stringify(got)}`);
      const dark = await capture("rail-update-dark");
      await run(`st().updateSettings({ theme: "light" }); return true;`);
      await sleep(800);
      const light = await capture("rail-update-light");
      await toggle();
      await widthIs(240);
      await sleep(400);
      const fullLight = await capture("full-update-light");
      await toggle();
      await widthIs(84);
      await run(`st().updateSettings({ theme: "dark" }); return true;`);
      return { update: got.update, shots: { dark, light, fullLight } };
    } finally {
      await run(`return A.devSimulatePendingUpdate(null, "count");`).catch(() => {});
    }
  });

  await rep.check("toggling again restores the saved full width", async () => {
    await toggle();
    const c = await widthIs(240);
    const s = await run(`return { iconsOnly: st().settings.sidebarIconsOnly, width: st().settings.sidebarWidth };`);
    if (s.iconsOnly || s.width !== 240) throw new Error(`settings after leaving the rail: ${JSON.stringify(s)}`);
    return { width: c.width };
  });

  await rep.check("the Settings switch is the same setting", async () => {
    await run(`st().updateSettings({ sidebarIconsOnly: true }); return true;`);
    await widthIs(84);
    await run(`st().updateSettings({ sidebarIconsOnly: false }); return true;`);
    const c = await widthIs(240);
    return { width: c.width };
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

#!/usr/bin/env node
import { mkdtempSync, rmSync, mkdirSync, writeFileSync } from "node:fs";
import { createServer } from "node:http";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { launch, reporter, session, sleep } from "../../../scripts/lib/instance.mjs";

const args = process.argv.slice(2);
const appArg = args.find((a) => !a.startsWith("--"));
if (!appArg || resolve(appArg).startsWith("/Applications/")) {
  console.error(`usage: node webkit-pill-test.mjs <Debug Solara.app under apps/browser/build-*> [--keep-data]

On a page open in WebKit the toolbar's pinned extensions, cast included, give way to a "WebKit" pill: with tabs on top
it sits where the extensions were and a click opens its popover, whose Open Page in Chromium moves the page back and
brings the extensions back; with the address bar in the sidebar the pill is the field's accessory. Chrome's cast dialog
can't open for a WebKit tab, so the popover lists casting too.`);
  process.exit(2);
}
const keep = args.includes("--keep-data");
const scratch = mkdtempSync(join(tmpdir(), "ac-webkit-pill-"));
const rep = reporter(join(scratch, "webkit-pill-test.log"), { name: "webkit-pill-test" });
const server = createServer((req, res) => {
  res.writeHead(200, { "content-type": "text/html" });
  res.end("<!doctype html><title>Engine Fixture</title><p>engine fixture</p>");
});
await new Promise((r) => server.listen(0, "127.0.0.1", r));
const pageUrl = `http://127.0.0.1:${server.address().port}/engine`;
const fixture = session({
  profiles: [{ id: "default", name: "Personal" }],
  windows: [{ id: "w1", frame: [80, 80, 1280, 800], activeTabIds: { default: "t0" } }],
  tabs: [{ id: "t0", url: pageUrl, title: "Engine Fixture" }],
  settings: { tabLayout: "top", warnBeforeClosingLastTab: false, warnBeforeClosingWindow: false, warnBeforeQuitting: false },
});
const HELPERS = `
const C = globalThis.expo.modules.SolaraCEF;
const T = globalThis.expo.modules.SolaraToolbar;
const B = globalThis.expo.modules.SolaraSidebarAddressBar;
const st = () => ac.store.getState();
const settle = (ms) => new Promise((r) => setTimeout(r, ms));
const win = () => C.chromeWindows().then((ws) => ws.find((w) => w.hasRoot).window);
const act = (a) => win().then((n) => C.devWindow(n, a));
const click = (x, y) => act("mouse:down:" + x + "," + y + ",1").then(() => settle(30)).then(() => act("mouse:up:" + x + "," + y + ",1")).then(() => settle(150));
const bar = () => T.devToolbar("w1", "t0").then((j) => JSON.parse(j));
const engine = () => st().tabs.t0.engine ?? "chromium";
const browserId = () => Number(Object.entries(ac.pageState.getState().browsers).find(([, tab]) => tab === "t0")?.[0] ?? 0);

`;
let inst = null;
let extensionId = null;
const run = (body, timeout = 30000) => inst.eval(`${HELPERS}\n${body}`, { timeout });
const until = async (what, body, accept, ms = 8000) => {
  const end = Date.now() + ms;
  let last;
  while (Date.now() < end) {
    last = await run(body).catch((e) => ({ error: e.message }));
    if (accept(last)) return last;
    await sleep(150);
  }
  throw new Error(`${what}: ${JSON.stringify(last)}`);
};
const env = { ...(process.env.SOLARA_EXTENSION_ACTION_POLL ? { SOLARA_EXTENSION_ACTION_POLL: process.env.SOLARA_EXTENSION_ACTION_POLL } : {}), SOLARA_NATIVE_SHELL: "1", SOLARA_NATIVE_TOP_STRIP: "1" };
const ids = (b) => (b?.extensions ?? []).map((e) => e.id);

try {
  inst = await launch(resolve(appArg), { data: join(scratch, "data"), fresh: true, session: fixture, onboarded: true, env, ready: "return !!ac.store.getState().windows.w1" });
  await sleep(2500);

  await rep.check("(a) a Chromium page shows its pinned extension in the toolbar", async () => {
    const directory = join(scratch, "extension");
    mkdirSync(directory, { recursive: true });
    writeFileSync(join(directory, "manifest.json"), JSON.stringify({ manifest_version: 3, name: "WebKit Pill Fixture", version: "1.0", action: {} }));
    const installed = await run(`return globalThis.expo.modules.SolaraExtensions.install(${JSON.stringify(directory)}, "");`);
    if (!/^[a-p]{32}$/.test(installed?.id) || installed.error) throw new Error(JSON.stringify(installed));
    extensionId = installed.id;
    await run(`return T.extensionCommand(JSON.stringify({ command: "setPinned", profile: "", id: ${JSON.stringify(extensionId)}, pinned: true }));`);
    if (!await run(`return T.devExtensionCatalog().then((catalog) => catalog.native);`)) throw new Error("native catalog unavailable");
    const b = await until("the extension button", `return bar();`, (b) => ids(b).includes(`ext:${extensionId}`));
    if (ids(b).includes("webkit")) throw new Error(JSON.stringify(b));
    return { extensions: ids(b) };
  });

  await rep.check("(b) in WebKit the extensions give way to the WebKit pill", async () => {
    await run(`ac.runCommand({ command: "togglePageEngine", arg: null, windowId: "w1" }); return true;`);
    await until("the WebKit engine", `return engine();`, (e) => e === "webkit", 15000);
    const b = await until("the pill", `return bar();`, (b) => ids(b).length === 1 && ids(b)[0] === "webkit" && b.extensions[0].frame[2] > 0, 10000);
    const pill = b.extensions[0];
    if (pill.label !== "WebKit" || pill.frame[2] < 60) throw new Error(JSON.stringify(b));
    return { pill: pill.frame };
  });

  await rep.check("(c) Chrome's cast dialog can't open for a WebKit tab", async () => {
    const id = await run(`return browserId();`);
    const opened = await run(`return globalThis.expo.modules.SolaraChromeUI.showCastDialog(${id});`);
    if (!(id < 0) || opened !== false) throw new Error(JSON.stringify({ id, opened }));
    return { browserId: id, opened };
  });

  await rep.check("(d) a click on the pill opens its popover", async () => {
    const b = await run(`return bar();`);
    const [x, y, w, h] = b.extensions[0].frame;
    await run(`return click(${Math.round(x + w / 2)}, ${Math.round(y + h / 2)});`);
    const shown = await until("the popover", `return bar();`, (b) => b?.infoPopover?.title, 5000);
    const p = shown.infoPopover;
    if (p.title !== "This page is open in WebKit" || !/^Extensions, password autofill and casting don't run here\.$/.test(p.message) || p.action !== "Open Page in Chromium")
      throw new Error(JSON.stringify(p));
    return p;
  });

  await rep.check("(e) Open Page in Chromium moves the page back and the extension returns", async () => {
    await run(`return T.devInfoPopover("press");`);
    await until("the Chromium engine", `return engine();`, (e) => e === "chromium", 15000);
    const b = await until("the extension back", `return bar();`, (b) => ids(b).includes(`ext:${extensionId}`) && !ids(b).includes("webkit"), 10000);
    if (b.infoPopover !== null) throw new Error(JSON.stringify(b));
    const id = await until("a Chromium browser", `return browserId();`, (id) => id > 0, 10000);
    return { extensions: ids(b), browserId: id };
  });

  await rep.check("(f) with the address bar in the sidebar the pill is the field's accessory", async () => {
    await run(`st().updateSettings({ tabLayout: "sidebar", addressBar: "sidebar" }); return settle(1500);`);
    await run(`ac.runCommand({ command: "togglePageEngine", arg: null, windowId: "w1" }); return true;`);
    await until("the WebKit engine", `return engine();`, (e) => e === "webkit", 15000);
    const s = await until("the sidebar pill", `return B.sample("w1").then((j) => JSON.parse(j));`,
      (s) => (s?.["field.sample"]?.buttons ?? []).some((b) => b.id === "webkit" && b.frame[2] > 0), 10000);
    const buttons = s["field.sample"].buttons;
    const pill = buttons.find((b) => b.id === "webkit");
    if (buttons.some((b) => b.id.startsWith("ext")) || pill.frame[2] < 60) throw new Error(JSON.stringify(buttons));
    return { pill: pill.frame };
  });
} catch (e) {
  rep.record("run", { error: e });
} finally {
  if (inst && extensionId) await run(`return globalThis.expo.modules.SolaraExtensions.uninstall(${JSON.stringify(extensionId)}, "");`).catch(() => null);
  await inst?.quit();
  server.close();
}
const ok = rep.summary();
if (!keep) rmSync(scratch, { recursive: true, force: true });
process.exit(ok ? 0 : 1);

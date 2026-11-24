#!/usr/bin/env node
import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { launch, reporter } from "../../../scripts/lib/instance.mjs";

const HELP = "usage: node apps/browser/scripts/safe-mode-workspace-test.mjs <Debug Solara.app> [--keep-data]\n\nReads ac.native.state() on every query; null means an unavailable native workspace and readiness cannot pass.\n\nSafe mode, entered through an isolated launch-switch defaults suite on data a normal launch made first, in hidden windows: a sidebar group header collapses and expands, its close button asks first and Cancel keeps it while Close Group closes it, the group menu collapses and ungroups, and a link dropped on the sidebar opens a tab. Swift's Debug counters must rise by one per action, so the native store decides these in safe mode. A normal relaunch on the same data shows none of it, because safe mode never saves the workspace.";
const args = process.argv.slice(2);
if (args.includes("--help") || !args.find((a) => !a.startsWith("--"))) {
  console.log(HELP);
  process.exit(args.includes("--help") ? 0 : 2);
}
const appPath = resolve(args.find((a) => !a.startsWith("--")));
assert.ok(!appPath.startsWith("/Applications/") && !appPath.includes("/build-vista/"), "use an isolated Debug app");
const keep = args.includes("--keep-data");
const scratch = mkdtempSync(join(tmpdir(), "ac-safe-workspace-"));
const data = join(scratch, "data");
const suite = `solara-safe-workspace-test-${process.pid}-${Date.now()}`;
const rep = reporter(join(scratch, "safe-mode-workspace-test.log"), { name: "safe-mode-workspace-test" });
const page = (id) => `data:text/html,<title>${id}</title>${id}`;
const DROPPED = "https://example.com/safe-mode-drop";

const HELPERS = `
const C = globalThis.expo.modules.SolaraCEF;
const D = globalThis.expo.modules.SolaraSidebarDrag;
const M = globalThis.expo.modules.SolaraShell;
const st = () => ac.native.state();
const settle = (ms) => new Promise((r) => setTimeout(r, ms));
const win = (id) => C.chromeWindows().then((ws) => { const f = st().windows[id].frame; const w = ws.filter((w) => w.hasRoot).find((w) => { const r = w.frame.match(/[-\\d.]+/g).map(Number); return Math.abs(r[0] - f[0]) < 2 && Math.abs(r[2] - f[2]) < 2; }); return w && w.window; });
const point = (id, x, y) => ac.shell.devSetPointer(id, { x, y });
const click = (id, x, y) => Promise.resolve(point(id, x, y)).then(() => settle(250)).then(() => win(id)).then((n) => C.devWindow(n, "mouse:down:" + x + "," + y + ",1").then(() => settle(40)).then(() => C.devWindow(n, "mouse:up:" + x + "," + y + ",1"))).then(() => settle(450));
const rightClick = (id, x, y) => win(id).then((n) => C.devWindow(n, "click:" + x + "," + y + ",right")).then(() => settle(350));
const hits = (id, xs, ys) => win(id).then((n) => Promise.all(xs.flatMap((x) => ys.map((y) => C.devWindow(n, "hit:" + x + "," + y).then((h) => [x, y, h])))));
const sheet = (id) => win(id).then((n) => C.devWindow(n, "winfo")).then((t) => JSON.parse(t));
const col = (id) => globalThis.expo.modules.SolaraHosted.sidebarShell(id).then((d) => JSON.parse(d));
const counters = (id) => Promise.all([D.devGroupActions(), D.devGroupMenus(), col(id).then((c) => c?.nativeDrops ?? null)]).then(([actions, menus, drops]) => ({ actions, menus, drops }));
`;

let app;
const run = (body) => app.eval(`${HELPERS}\n${body}`, { timeout: 30000 });
const range = (from, count) => Array.from({ length: Math.max(0, Math.ceil(count)) }, (_, i) => Math.round(from) + i);
const q = JSON.stringify;
let W;

const requireSwift = (what, counter, before, after) => {
  rep.log(`${what}: ${counter} ${before} -> ${after}`);
  console.log(`${what}: ${counter} ${before} -> ${after}`);
  assert.equal(typeof before, "number", `${what}: the Debug counter ${counter} is readable`);
  assert.equal(after - before, 1, `${what}: Swift decided it in safe mode (${counter} ${before} -> ${after})`);
};
const swiftDid = async (what, counter, act) => {
  const before = await run(`return counters(${q(W)});`);
  await act();
  const after = await run(`return counters(${q(W)});`);
  requireSwift(what, counter, before[counter], after[counter]);
};

const header = async (groupId) => {
  const probe = JSON.parse(await run(`return D.startProbe(${q(W)});`));
  const item = probe?.items.find((i) => i.kind === "group" && (i.groupId === groupId || String(i.key).includes(groupId)));
  assert.ok(item && item.w > 0, `a header for ${groupId}: ${q(probe?.items.map((i) => [i.kind, i.groupId, i.key]))}`);
  const column = await run(`return hits(${q(W)}, [${Math.round(item.x + Math.min(60, item.w / 3))}], ${q(range(item.y, Math.min(item.h, 60)))});`);
  const ys = column.filter(([, , h]) => /GroupHeaderView/.test(h)).map(([, y]) => y);
  assert.ok(ys.length, `the header row of ${groupId}`);
  return { x: item.x, w: item.w, y: Math.round((ys[0] + ys.at(-1)) / 2) };
};

const closeButton = async (groupId) => {
  const h = await header(groupId);
  await run(`return Promise.resolve(point(${q(W)}, ${Math.round(h.x + h.w / 2)}, ${h.y})).then(() => settle(450));`);
  const row = await run(`return hits(${q(W)}, ${q(range(h.x, h.w))}, [${h.y}]);`);
  const xs = row.filter(([, , hit]) => !/^SolaraUI\.GroupHeaderView|^NSView|^SolaraUI\.SidebarDocumentView/.test(hit)).map(([x]) => x);
  assert.ok(xs.length, `a close button in ${groupId}'s header`);
  const last = xs.at(-1);
  let first = last;
  while (xs.includes(first - 1)) first -= 1;
  return [Math.round((first + last) / 2), h.y];
};

const untilSheet = async (want, ms = 6000) => {
  const deadline = Date.now() + ms;
  let last;
  while (Date.now() < deadline) {
    last = await run(`return sheet(${q(W)});`);
    if (!!last.sheet === want) return last;
    await new Promise((r) => setTimeout(r, 100));
  }
  throw new Error(`the sheet ${want ? "never appeared" : "never went away"} (${q(last)})`);
};
const sheetKey = (info, chars, code) => run(`return C.devWindow(${info.sheetWindow}, "keys:0:${chars}:${code}");`);

const menuChoice = async (groupId, choice) => {
  assert.equal(typeof (await run(`return M.devContextMenu("arm", ${q(choice)});`)), "object");
  const h = await header(groupId);
  await run(`return rightClick(${q(W)}, ${Math.round(h.x + Math.min(60, h.w / 3))}, ${h.y});`);
  const deadline = Date.now() + 4000;
  let model;
  while (Date.now() < deadline) {
    model = await run(`return M.devContextMenu("read", null);`);
    if (Array.isArray(model?.items)) break;
    await new Promise((r) => setTimeout(r, 80));
  }
  assert.ok(Array.isArray(model?.items), `a menu was built (${q(model)})`);
  assert.equal(model.accepted, true, `the menu took ${choice}`);
  await run(`return settle(600);`);
};

const group = (ids, name) => run(`const id = ac.native.command("createGroup", ${q(ids)}, { name: ${q(name)} }); return settle(1300).then(() => id);`);
const groupNamed = (name) => run(`return Object.values(st().groups).find((g) => g.name === ${q(name)})?.id ?? null;`);

const env = { SOLARA_NATIVE_SHELL: "1", SOLARA_NATIVE_TOP_STRIP: "1", SOLARA_DRAW_WINDOWS: "1" };
try {
  app = await launch(appPath, { data, fresh: true, onboarded: true, env, ready: "return Object.keys(ac.native.state()?.windows ?? {}).length > 0" });
  await run(`ac.native.command("updateSettings", { warnBeforeClosingTabGroup: true, warnBeforeClosingLastTab: false, warnBeforeClosingWindow: false }); return settle(1500);`);
  await app.quit();
  app = await launch(appPath, { data, onboarded: true, env: { ...env, SOLARA_LAUNCH_SWITCHES_DEFAULTS: suite, SOLARA_LAUNCH_SWITCHES_OPTION: "1" }, ready: "return Object.keys(ac.native.state()?.windows ?? {}).length > 0" });
  rep.log(`instance: pid ${app.pid}, data ${data}, defaults suite ${suite}`);

  await rep.check("the instance is in safe mode and the native store owns the workspace", async () => {
    const status = await run(`return ac.native.status();`);
    assert.equal(status.active, true, q(status));
    assert.equal(status.safeMode, "option", q(status));
    assert.equal(await run(`return st().settings.warnBeforeClosingTabGroup;`), true, "safe mode read the saved settings");
    assert.equal(await run(`return ac.nativePages.ownsLive();`), true, "JS sees an owned workspace");
    W = await run(`return Object.keys(st().windows)[0];`);
    assert.equal(await run(`return win(${q(W)}).then((n) => C.devWindow(n, "alertSheets:1"));`), "1", "real sheets in this test instance");
  });

  const tabs = await run(`const ids = ${q(["a", "b", "c", "d"].map(page))}.map((url) => ac.native.command("newTab", ${q(W)}, { url, background: true }));
    return settle(1200).then(() => ids);`);
  const work = await group(tabs.slice(0, 2), "Work");

  await rep.check("a click on a group header collapses it and another expands it, decided in Swift", async () => {
    let h = await header(work);
    for (let i = 0; i < 10; i++) {
      await run(`return settle(400);`);
      const again = await header(work);
      if (again.x === h.x && again.y === h.y && again.w === h.w) break;
      h = again;
    }
    const x = Math.round(h.x + Math.min(60, h.w / 3));
    rep.log(`collapse at ${x},${h.y}: ${await run(`return win(${q(W)}).then((n) => C.devWindow(n, "firstMouse:${x},${h.y}"));`)}`);
    await swiftDid("collapse", "actions", () => run(`return click(${q(W)}, ${x}, ${h.y});`));
    assert.equal(await run(`return st().groups[${q(work)}].collapsed;`), true);
    await swiftDid("expand", "actions", () => run(`return click(${q(W)}, ${x}, ${h.y});`));
    assert.equal(await run(`return st().groups[${q(work)}].collapsed;`), false);
  });

  await rep.check("the close button asks in a sheet; Cancel keeps the group and Close Group closes it", async () => {
    let [x, y] = await closeButton(work);
    await swiftDid("close (cancel)", "actions", () => run(`return click(${q(W)}, ${x}, ${y});`));
    const shown = await untilSheet(true);
    assert.ok(shown.sheetText.includes("Close “Work”?"), shown.sheetText.join(" | "));
    await sheetKey(shown, "\\u001b", 53);
    await untilSheet(false);
    assert.ok(await run(`return !!st().groups[${q(work)}];`), "Cancel keeps the group");
    [x, y] = await closeButton(work);
    await swiftDid("close (confirm)", "actions", () => run(`return click(${q(W)}, ${x}, ${y});`));
    const again = await untilSheet(true);
    await sheetKey(again, "\\r", 36);
    await untilSheet(false);
    await run(`return settle(600);`);
    assert.equal(await run(`return !!st().groups[${q(work)}];`), false, "Close Group closes it");
    assert.deepEqual(await run(`return ${q(tabs.slice(0, 2))}.filter((id) => st().tabs[id]);`), [], "its tabs close with it");
  });

  const menu = await group(tabs.slice(2), "Menu");
  await rep.check("the group menu collapses and ungroups, decided in Swift", async () => {
    await swiftDid("menu collapse", "menus", () => menuChoice(menu, "collapse"));
    assert.equal(await run(`return st().groups[${q(menu)}].collapsed;`), true);
    await swiftDid("menu ungroup", "menus", () => menuChoice(menu, "ungroup"));
    assert.equal(await run(`return !!st().groups[${q(menu)}];`), false, "ungrouped");
    assert.deepEqual(await run(`return ${q(tabs.slice(2))}.filter((id) => st().tabs[id]);`), tabs.slice(2), "its tabs stay");
  });

  await rep.check("a link dropped on the sidebar opens a tab, decided in Swift", async () => {
    const column = await run(`return col(${q(W)});`);
    assert.ok(Array.isArray(column?.frame), `the native sidebar column: ${q(column)}`);
    const x = Math.round(column.frame[0] + column.frame[2] / 2);
    const y = Math.round(column.frame[1] + column.frame[3] - 12);
    await swiftDid("link drop", "drops", () => run(`const FD = ac.shell.devFileDrag;
      return FD.drag(${q(W)}, "move", ${x}, ${y}, { urls: [${q(DROPPED)}] }).then(() => settle(400)).then(() => FD.drag(${q(W)}, "drop", ${x}, ${y})).then(() => settle(1200));`));
    assert.ok(await run(`return Object.values(st().tabs).some((t) => t.url === ${q(DROPPED)});`), "the dropped link is a tab");
  });

  await rep.check("a normal relaunch on the same data shows none of safe mode's workspace edits", async () => {
    await app.quit();
    app = await launch(appPath, { data, onboarded: true, env, ready: "return Object.keys(ac.native.state()?.windows ?? {}).length > 0" });
    rep.log(`relaunched normally: pid ${app.pid}`);
    const status = await run(`return ac.native.status();`);
    assert.ok(status.active && !status.safeMode, q(status));
    assert.equal(await groupNamed("Menu"), null, "no group from safe mode");
    assert.equal(await run(`return Object.values(st().tabs).some((t) => t.url === ${q(DROPPED)});`), false, "no tab from safe mode's drop");
  });
} finally {
  await app?.quit();
  try { execFileSync("defaults", ["delete", suite], { stdio: "ignore" }); } catch {}
  if (!keep) rmSync(data, { recursive: true, force: true });
}
process.exit(rep.summary() ? 0 : 1);

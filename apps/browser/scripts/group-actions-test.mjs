#!/usr/bin/env node
import assert from "node:assert/strict";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { launch, reporter, session } from "../../../scripts/lib/instance.mjs";
import { sidebarSession } from "./sidebar-position-test.mjs";

const HELP = "usage: node apps/browser/scripts/group-actions-test.mjs <Debug Solara.app> [--keep-data]\n\nA group's buttons in the sidebar and the top strip, clicked for real in hidden windows, with the close warning as a real window sheet: the header collapses and expands; its close button asks first (title, text, buttons), Cancel keeps the group, a group removed while its sheet is open is left alone when the sheet confirms, Close with Don't ask again closes it and turns the warning off, and with the warning off it closes at once; a private window's warning drops the Recently Closed hint; a pinned group's button unloads instead; a strip chip collapses; and a collapsed strip group's visible member tucks to the last-used tab of the group's profile. In a build where Swift owns these buttons, its Debug counter rises by one per press and the test requires it.";
const args = process.argv.slice(2);
if (args.includes("--help") || !args.find((a) => !a.startsWith("--"))) {
  console.log(HELP);
  process.exit(args.includes("--help") ? 0 : 2);
}
const appPath = resolve(args.find((a) => !a.startsWith("--")));
assert.ok(!appPath.startsWith("/Applications/") && !appPath.includes("/build-vista/"), "use an isolated Debug app");
const keep = args.includes("--keep-data");
const scratch = mkdtempSync(join(tmpdir(), "ac-group-actions-"));
const rep = reporter(join(scratch, "group-actions-test.log"), { name: "group-actions-test" });
const page = (id) => `data:text/html,<title>${id}</title>${id}`;
const fixture = session(sidebarSession({
  windows: [{ id: "w1", frame: [80, 80, 1100, 760], activeTabIds: { default: "f" } }],
  tabs: ["a", "b", "c", "d", "e", "f", "g"].map((id) => ({ id, url: page(id), title: id.toUpperCase() })),
  settings: { warnBeforeClosingLastTab: false, warnBeforeClosingWindow: false, warnBeforeClosingTabGroup: true },
}));
const SUPPRESS = "Don’t ask me again";

const HELPERS = `
const C = globalThis.expo.modules.SolaraCEF;
const D = globalThis.expo.modules.SolaraSidebarDrag;
const st = () => ac.store.getState();
const settle = (ms) => new Promise((r) => setTimeout(r, ms));
const win = (id) => C.chromeWindows().then((ws) => { const f = st().windows[id].frame; const w = ws.filter((w) => w.hasRoot).find((w) => { const r = w.frame.match(/[-\\d.]+/g).map(Number); return Math.abs(r[0] - f[0]) < 2 && Math.abs(r[2] - f[2]) < 2; }); return w && w.window; });
const point = (id, x, y) => ac.shell.devSetPointer(id, { x, y });
const click = (id, x, y) => Promise.resolve(point(id, x, y)).then(() => settle(250)).then(() => win(id)).then((n) => C.devWindow(n, "mouse:down:" + x + "," + y + ",1").then(() => settle(40)).then(() => C.devWindow(n, "mouse:up:" + x + "," + y + ",1"))).then(() => settle(450));
const hits = (id, xs, ys) => win(id).then((n) => Promise.all(xs.flatMap((x) => ys.map((y) => C.devWindow(n, "hit:" + x + "," + y).then((h) => [x, y, h])))));
const handled = () => typeof D.devGroupActions === "function" ? D.devGroupActions() : Promise.resolve(null);
const sheet = (id) => win(id).then((n) => C.devWindow(n, "winfo")).then((t) => JSON.parse(t));
const sheetRows = (n, w, h) => Promise.all([Math.round(w * 0.2), Math.round(w * 0.35), Math.round(w / 2)].flatMap((x) => Array.from({ length: Math.floor(h / 2) }, (_, i) => i * 2).map((y) => C.devWindow(n, "hit:" + x + "," + y).then((hit) => [x, y, hit]))));
`;

let app;
const run = (body) => app.eval(`${HELPERS}\n${body}`, { timeout: 30000 });
const range = (from, count) => Array.from({ length: Math.max(0, Math.ceil(count)) }, (_, i) => Math.round(from) + i);
let swiftOwned = null;

const sheetNow = (windowId) => run(`return sheet(${JSON.stringify(windowId)});`);
const untilSheet = async (windowId, want, ms = 6000) => {
  const deadline = Date.now() + ms;
  let last;
  while (Date.now() < deadline) {
    last = await sheetNow(windowId);
    if (!!last.sheet === want) return last;
    await new Promise((r) => setTimeout(r, 100));
  }
  throw new Error(`${windowId}: the sheet ${want ? "never appeared" : "never went away"} (${JSON.stringify(last)})`);
};
const noSheetFor = async (windowId, ms = 1200) => {
  const deadline = Date.now() + ms;
  while (Date.now() < deadline) {
    const info = await sheetNow(windowId);
    assert.equal(info.sheet, "", `no sheet on ${windowId}: ${JSON.stringify(info.sheetText)}`);
    await new Promise((r) => setTimeout(r, 120));
  }
};
const sheetKey = (info, chars, code) => run(`return C.devWindow(${info.sheetWindow}, "keys:0:${chars}:${code}");`);
const escape = (info) => sheetKey(info, "\\u001b", 53);
const confirm = (info) => sheetKey(info, "\\r", 36);
const tickSuppression = async (info) => {
  const [w, h] = info.sheet.match(/[-\d.]+/g).map(Number).slice(2, 4);
  const hits = await run(`return sheetRows(${info.sheetWindow}, ${w}, ${h});`);
  const ys = [...new Set(hits.filter(([, , hit]) => /^NSButton\b/.test(hit)).map(([, y]) => y))].sort((a, b) => a - b);
  assert.ok(ys.length, `buttons in the sheet: ${JSON.stringify([...new Set(hits.map(([, , hit]) => hit.split(" < ")[0]))])}`);
  let last = ys[0];
  while (ys.includes(last + 2)) last += 2;
  const y = Math.round((ys[0] + last) / 2);
  const x = hits.find(([, hy, hit]) => hy === ys[0] && /^NSButton\b/.test(hit))[0];
  await run(`return C.devWindow(${info.sheetWindow}, "mouse:down:${x},${y},1").then(() => settle(60)).then(() => C.devWindow(${info.sheetWindow}, "mouse:up:${x},${y},1")).then(() => settle(200));`);
  rep.log(`ticked the sheet's top button row at ${x},${y} (rows ${ys[0]}..${ys.at(-1)})`);
};

const counted = async (what, press) => {
  const before = await run(`return handled();`);
  await press();
  const after = await run(`return handled();`);
  if (swiftOwned === null) swiftOwned = typeof before === "number";
  if (swiftOwned) {
    assert.equal(typeof after, "number", `${what}: the Swift counter is readable`);
    assert.equal(after - before, 1, `${what}: Swift handled the press (${before} -> ${after})`);
  }
  rep.log(`${what}: Swift-handled presses ${before} -> ${after}`);
  console.log(`${what}: Swift-handled presses ${before} -> ${after}`);
};

const header = async (windowId, groupId) => {
  const probe = JSON.parse(await run(`return D.startProbe(${JSON.stringify(windowId)});`));
  const item = probe?.items.find((i) => i.kind === "group" && (i.groupId === groupId || String(i.key).includes(groupId)));
  assert.ok(item && item.w > 0, `a header for ${groupId}: ${JSON.stringify(probe?.items.map((i) => [i.kind, i.groupId, i.key]))}`);
  const x = Math.round(item.x + item.w / 2);
  const column = await run(`return hits(${JSON.stringify(windowId)}, [${x}], ${JSON.stringify(range(item.y, Math.min(item.h, 60)))});`);
  const ys = column.filter(([, , h]) => /GroupHeaderView/.test(h)).map(([, y]) => y);
  assert.ok(ys.length, `the header row of ${groupId}: ${JSON.stringify([...new Set(column.map(([, , h]) => h.split(" < ")[0]))])}`);
  return { x: item.x, w: item.w, y: Math.round((ys[0] + ys.at(-1)) / 2) };
};

const buttonIn = async (windowId, x0, w, y, hoverX, outside) => {
  await run(`return Promise.resolve(point(${JSON.stringify(windowId)}, ${hoverX}, ${y})).then(() => settle(450));`);
  const row = await run(`return hits(${JSON.stringify(windowId)}, ${JSON.stringify(range(x0, w))}, [${y}]);`);
  const xs = row.filter(([, , h]) => !outside.test(h)).map(([x]) => x);
  assert.ok(xs.length, `a button in the row: ${JSON.stringify([...new Set(row.map(([, , h]) => h.split(" < ")[0]))])}`);
  const last = xs.at(-1);
  let first = last;
  while (xs.includes(first - 1)) first -= 1;
  return [Math.round((first + last) / 2), y];
};

const closeButton = async (windowId, groupId) => {
  const h = await header(windowId, groupId);
  return buttonIn(windowId, h.x, h.w, h.y, Math.round(h.x + h.w / 2), /^SolaraUI\.GroupHeaderView|^NSView|^SolaraUI\.SidebarDocumentView/);
};

const group = (ids, name) => run(`const id = st().createGroup(${JSON.stringify(ids)}, { name: ${JSON.stringify(name)} }); return settle(1300).then(() => id);`);
const exists = (id) => run(`return !!st().groups[${JSON.stringify(id)}];`);

try {
  app = await launch(appPath, { data: join(scratch, "data"), fresh: true, session: fixture, onboarded: true, env: { SOLARA_NATIVE_SHELL: "1", SOLARA_NATIVE_TOP_STRIP: "1", SOLARA_DRAW_WINDOWS: "1" }, ready: "return !!ac.store.getState().windows.w1" });
  rep.log(`instance: pid ${app.pid}, data ${join(scratch, "data")}`);
  assert.equal(await run(`return win("w1").then((n) => C.devWindow(n, "alertSheets:1"));`), "1", "real sheets in this test instance");
  const work = await group(["a", "b"], "Work");

  await rep.check("a click on the sidebar group header collapses it, and another expands it", async () => {
    const h = await header("w1", work);
    const x = Math.round(h.x + Math.min(60, h.w / 3));
    await counted("sidebar collapse", () => run(`return click("w1", ${x}, ${h.y});`));
    assert.equal(await run(`return st().groups[${JSON.stringify(work)}].collapsed;`), true);
    await counted("sidebar expand", () => run(`return click("w1", ${x}, ${h.y});`));
    assert.equal(await run(`return st().groups[${JSON.stringify(work)}].collapsed;`), false);
  });

  await rep.check("the close button asks first in a window sheet, and Cancel keeps the group", async () => {
    const [x, y] = await closeButton("w1", work);
    await counted("sidebar close (cancel)", () => run(`return click("w1", ${x}, ${y});`));
    const shown = await untilSheet("w1", true);
    const text = shown.sheetText.join(" | ");
    assert.ok(shown.sheetText.includes("Close “Work”?") && shown.sheetText.includes("Its 2 tabs close with it. History › Recently Closed Groups brings it back."), text);
    for (const b of ["Close Group", "Cancel", SUPPRESS]) assert.ok(shown.sheetText.includes(b), `${b} in ${text}`);
    await run(`return click("w1", ${x}, ${y});`);
    await run(`return settle(400);`);
    assert.equal((await sheetNow("w1")).sheetWindow, shown.sheetWindow, "the same sheet after a second press");
    assert.ok(await exists(work), "the group is still there under the sheet");
    await escape(shown);
    await untilSheet("w1", false);
    await noSheetFor("w1", 600);
    assert.ok(await exists(work), "Cancel keeps the group");
    assert.equal(await run(`return st().settings.warnBeforeClosingTabGroup;`), true);
  });

  await rep.check("a group removed while its sheet is open is left alone when the sheet confirms", async () => {
    const gone = await group(["c"], "Gone");
    const [x, y] = await closeButton("w1", gone);
    await counted("sidebar close (removed meanwhile)", () => run(`return click("w1", ${x}, ${y});`));
    const shown = await untilSheet("w1", true);
    await run(`st().ungroup(${JSON.stringify(gone)}); return settle(400);`);
    assert.equal(await exists(gone), false, "the group is gone under the sheet");
    const tabs = await run(`return st().windows.w1.tabIds;`);
    await confirm(shown);
    await untilSheet("w1", false);
    await run(`return settle(600);`);
    assert.deepEqual(await run(`return st().windows.w1.tabIds;`), tabs, "Close Group on a gone group closes nothing");
    assert.equal(await exists(gone), false);
    assert.ok(await run(`return !!st().tabs.c;`), "the ex-member tab stays open");
  });

  await rep.check("Close with Don't ask again closes the group and turns the warning off", async () => {
    const [x, y] = await closeButton("w1", work);
    await counted("sidebar close (confirm)", () => run(`return click("w1", ${x}, ${y});`));
    const shown = await untilSheet("w1", true);
    await tickSuppression(shown);
    assert.equal((await sheetNow("w1")).sheetWindow, shown.sheetWindow, "ticking the box leaves the sheet up");
    await confirm(shown);
    await untilSheet("w1", false);
    await run(`return settle(600);`);
    assert.equal(await exists(work), false);
    assert.equal(await run(`return st().settings.warnBeforeClosingTabGroup;`), false);
    assert.deepEqual(await run(`return ["a", "b"].filter((id) => st().tabs[id]);`), []);
  });

  await rep.check("with the warning off, the close button closes at once", async () => {
    const solo = await group(["c"], "Solo");
    const [x, y] = await closeButton("w1", solo);
    await counted("sidebar close (no warning)", () => run(`return click("w1", ${x}, ${y});`));
    await noSheetFor("w1");
    assert.equal(await exists(solo), false);
    await run(`st().updateSettings({ warnBeforeClosingTabGroup: true }); return settle(300);`);
  });

  await rep.check("a private window's warning leaves out the Recently Closed hint", async () => {
    const [pw, gid] = await run(`const pw = st().createWindow({ incognito: true, frame: [240, 140, 900, 600], url: ${JSON.stringify(page("p1"))} });
      const extra = st().newTab(pw, { url: ${JSON.stringify(page("p2"))}, background: true });
      return settle(2500).then(() => { const id = st().createGroup(st().windows[pw].tabIds.slice(0, 2), { name: "Private" }); return settle(1500).then(() => [pw, id]); });`);
    try {
      const [x, y] = await closeButton(pw, gid);
      await counted("private close (cancel)", () => run(`return click(${JSON.stringify(pw)}, ${x}, ${y});`));
      const shown = await untilSheet(pw, true);
      assert.ok(shown.sheetText.includes("Close “Private”?") && shown.sheetText.includes("Its 2 tabs close with it."), shown.sheetText.join(" | "));
      await escape(shown);
      await untilSheet(pw, false);
      assert.ok(await exists(gid));
    } finally {
      await run(`st().closeWindow(${JSON.stringify(pw)}); return settle(900);`);
    }
  });

  await rep.check("a pinned group's button unloads its tabs instead of closing the group", async () => {
    const pinned = await group(["g"], "Pinned");
    await run(`st().updateGroup(${JSON.stringify(pinned)}, { pinned: true }); st().activate("g"); return settle(1200).then(() => { st().activate("f"); return settle(900); });`);
    const [x, y] = await closeButton("w1", pinned);
    await counted("pinned unload", () => run(`return click("w1", ${x}, ${y});`));
    await noSheetFor("w1");
    assert.ok(await exists(pinned), "the pinned group stays");
    assert.ok(await run(`return !!st().tabs.g;`), "its tab stays");
  });

  await rep.check("a click on a strip group's chip collapses it", async () => {
    const strip = await group(["d", "e"], "Strip");
    await run(`st().updateSettings({ tabLayout: "top" }); return settle(1800);`);
    const items = await run(`return globalThis.expo.modules.SolaraTopStrip.items("w1").then(JSON.parse).then((s) => s.items);`);
    const chip = items.find((i) => i.kind === "group" && i.id === strip);
    assert.ok(chip?.width > 0, JSON.stringify(items.map((i) => [i.kind, i.id])));
    await counted("strip collapse", () => run(`return click("w1", ${Math.round(chip.windowX + Math.min(20, chip.width / 2))}, 20);`));
    assert.equal(await run(`return st().groups[${JSON.stringify(strip)}].collapsed;`), true);
  });

  await rep.check("a collapsed strip group's visible member tucks to the last-used tab of the group's profile", async () => {
    const strip = await run(`return Object.values(st().groups).find((g) => g.name === "Strip").id;`);
    const other = await run(`const p = st().createProfile({ name: "Other", color: "blue" }); return settle(300).then(() => p);`);
    await run(`st().activate("f"); return settle(500).then(() => { st().activate("d"); return settle(500); }).then(() => { st().newTab("w1", { url: ${JSON.stringify(page("o1"))}, profileId: ${JSON.stringify(other)}, background: true }); return settle(400); })
      .then(() => { st().updateGroup(${JSON.stringify(strip)}, { collapsed: true }); return settle(1200); });`);
    const items = await run(`return globalThis.expo.modules.SolaraTopStrip.items("w1").then(JSON.parse).then((s) => s.items);`);
    const member = items.find((i) => i.kind === "tab" && i.id === "d");
    assert.ok(member?.width > 0, `the collapsed group's visible member: ${JSON.stringify(items.map((i) => [i.kind, i.id, i.windowX, i.width]))}`);
    await run(`return Promise.resolve(point("w1", ${Math.round(member.windowX + member.width / 2)}, 20)).then(() => settle(450));`);
    const row = await run(`return hits("w1", ${JSON.stringify(range(member.windowX, member.width))}, [20]);`);
    const xs = row.filter(([, , h]) => /^SolaraUI\.StripIconButton/.test(h)).map(([x]) => x);
    assert.ok(xs.length, `a Hide in Group button on the member: ${JSON.stringify([...new Set(row.map(([, , h]) => h.split(" < ")[0]))])}`);
    let first = xs.at(-1);
    while (xs.includes(first - 1)) first -= 1;
    const [x, y] = [Math.round((first + xs.at(-1)) / 2), 20];
    await counted("strip tuck", () => run(`return click("w1", ${x}, ${y});`));
    const active = await run(`const w = st().windows.w1; return { id: w.activeTabIds[w.profileId], profile: w.profileId };`);
    assert.equal(active.id, "f", `tucked to the last-used default-profile tab outside the group: ${JSON.stringify(active)}`);
    await run(`st().updateSettings({ tabLayout: "sidebar" }); return settle(1200);`);
  });

  rep.log(`Swift owned the group buttons in this build: ${swiftOwned}`);
  console.log(`Swift owned the group buttons in this build: ${swiftOwned}`);
} finally {
  await app?.quit();
  if (!keep) rmSync(join(scratch, "data"), { recursive: true, force: true });
}
process.exit(rep.summary() ? 0 : 1);

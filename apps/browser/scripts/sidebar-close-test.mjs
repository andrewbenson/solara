import assert from "node:assert/strict";
import { sidebarSession, assertSidebarPosition } from "./sidebar-position-test.mjs";
import { existsSync, mkdtempSync, readFileSync, rmSync } from "node:fs";
import { createServer } from "node:http";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { launch, reporter, session, sleep } from "../../../scripts/lib/instance.mjs";
import { fixturePage } from "../../../scripts/lib/fixture-html.mjs";

const args = process.argv.slice(2);
const appArg = args.find((a) => !a.startsWith("--"));
if (!appArg) {
  console.error("usage: node sidebar-close-test.mjs <Debug Solara.app> [--port=<DevTools port>] [--no-sheets] [--keep-data]\n\nA sidebar row's close button and a middle click, through AppKit's event path: a list row closes and the active one hands over to the store's successor, a middle click closes, a pinned row's button first unloads it and then removes it with an Undo toast that brings it back, a middle click on a pinned tile unloads it, the top strip's button closes its tab, the last list tab beside pinned tabs leaves a fresh tab without asking, a window's only tab asks first in a sheet whose Cancel keeps it and whose Close Tab closes it, closing a window's last tab of one profile asks with each profile's count while closing one with a sibling in its profile asks nothing, and Move Tab to Profile asks in a sheet whose Escape leaves the tab; every sheet is the real one, answered through its keys, the native snapshot agreeing after each. --no-sheets leaves out the sheet cases, for builds whose winfo has no sheetWindow.");
  process.exit(2);
}
const appPath = resolve(appArg);
const port = args.find((a) => a.startsWith("--port="))?.slice(7);
const keep = args.includes("--keep-data");
if (keep) process.env.AC_KEEP_DATA = "1";
const scratch = mkdtempSync(join(tmpdir(), "ac-sidebar-close-"));
const rep = reporter(join(scratch, "sidebar-close-test.log"), { name: "sidebar-close-test" });

const server = createServer((req, res) => {
  const name = req.url.slice(1) || "root";
  res.writeHead(200, { "content-type": "text/html" });
  res.end(fixturePage(name, { bodyStyle: "font:40px sans-serif" }));
});
await new Promise((r) => server.listen(0, "127.0.0.1", r));
const url = (name) => `http://127.0.0.1:${server.address().port}/${name}`;
const tab = (id, extra = {}) => ({ id, url: url(id), title: id.toUpperCase(), ...extra });
const soloFixture = session(sidebarSession({
  windows: [{ id: "w1", frame: [80, 80, 1280, 800], activeTabIds: { default: "solo" } }],
  tabs: [{ id: "solo", url: "", title: "" }],
}));
const profilesFixture = session(sidebarSession({
  profiles: ["Personal", "Work"],
  windows: [{ id: "w1", frame: [80, 80, 1280, 800], activeTabIds: { default: "x", work: "o" } }],
  tabs: [{ id: "x", url: "", title: "" }, { id: "o", profileId: "work", url: "about:blank#o", title: "O" }],
}));
const profilesWithSiblingFixture = session(sidebarSession({
  profiles: ["Personal", "Work"],
  windows: [{ id: "w1", frame: [80, 80, 1280, 800], activeTabIds: { default: "x", work: "o" } }],
  tabs: [{ id: "x", url: "", title: "" }, { id: "o", profileId: "work", url: "about:blank#o", title: "O" }, tab("m")],
}));
const stripFixture = session({
  windows: [{ id: "w1", frame: [80, 80, 1280, 800], activeTabIds: { default: "a" } }],
  tabs: [tab("a"), tab("b"), tab("d")],
  settings: { tabLayout: "top" },
});
const fixture = session(sidebarSession({
  windows: [{ id: "w1", frame: [80, 80, 1280, 800], activeTabIds: { default: "a" } }],
  tabs: [
    tab("p1", { pinned: true, pinnedUrl: url("p1") }),
    tab("pr", { pinned: true, pinnedUrl: url("pr"), pinnedAsRow: true }),
    tab("a"), tab("b"), tab("c"), tab("d"), tab("e"),
  ],
}));

let app = null;
let data = null;
const HELPERS = `
const C = globalThis.expo.modules.SolaraCEF;
const st = () => ac.store.getState();
const settle = (ms) => new Promise((r) => setTimeout(r, ms));
const win = () => C.chromeWindows().then((ws) => ws.find((w) => w.hasRoot).window);
const act = (a) => win().then((n) => C.devWindow(n, a));
const shown = () => st().windows.w1.activeTabIds[st().windows.w1.profileId];
const frame = (id) => ac.sidebarRows.measureRow("w1", id);
const point = (x, y) => ac.shell.devSetPointer("w1", { x, y });
const press = (kind, x, y) => act("mouse:" + kind + "down:" + x + "," + y).then(() => settle(70)).then(() => act("mouse:" + kind + "up:" + x + "," + y));
const closeButton = (id) => frame(id).then((f) => {
  if (!f) return null;
  const x = Math.round(f.x + 30), y = Math.round(f.y + f.height / 2), cx = Math.round(f.x + f.width - 17);
  return point(x, y).then(() => settle(350)).then(() => point(cx, y)).then(() => settle(150)).then(() => press("", cx, y)).then(() => settle(600)).then(() => true);
});
const open = (id) => frame(id).then((f) => {
  if (!f) return null;
  const x = Math.round(f.x + Math.min(f.width / 2, 60)), y = Math.round(f.y + f.height / 2);
  return point(x, y).then(() => press("", x, y)).then(() => settle(700)).then(() => shown());
});
const middle = (id) => frame(id).then((f) => {
  if (!f) return null;
  const x = Math.round(f.x + Math.min(f.width / 2, 40)), y = Math.round(f.y + f.height / 2);
  return point(x, y).then(() => settle(250)).then(() => press("other", x, y)).then(() => settle(600)).then(() => true);
});
const restoredPin = () => Object.values(st().tabs).filter((t) => t.windowId === "w1" && t.pinnedAsRow && (t.pinnedUrl || t.url).endsWith("/pr")).map((t) => t.id);
const view = () => { const s = st(); const w = s.windows.w1; return { shown: shown(), tabs: w.tabIds.filter((id) => s.tabs[id]), live: w.tabIds.filter((id) => s.tabs[id] && !s.tabs[id].unloaded) }; };
const toast = () => { const t = ac.toasts.getState().toasts.w1; return t ? { title: t.title, action: t.action?.title ?? null } : null; };
`;
const run = (body) => app.eval(`${HELPERS}\n${body}`, { timeout: 20000 });

const untilSnapshot = async (what, accept, ms = 5000) => {
  const deadline = Date.now() + ms;
  let last;
  while (Date.now() < deadline) {
    last = await app.snapshot({ windowId: "w1" }).catch((error) => ({ error: error.message }));
    if (!last.error && last.consistent && accept(last)) return last;
    await sleep(100);
  }
  throw new Error(`${what}: native snapshot never matched (${JSON.stringify(last)})`);
};
const untilView = async (what, accept, ms = 4000) => {
  const deadline = Date.now() + ms;
  let last;
  while (Date.now() < deadline) {
    last = await run("return view();");
    if (accept(last)) return last;
    await sleep(100);
  }
  throw new Error(`${what}: ${JSON.stringify(last)}`);
};

const untilRun = async (what, probe, ms = 4000) => {
  const deadline = Date.now() + ms;
  let last;
  while (Date.now() < deadline) {
    last = await probe();
    if (last) return last;
    await sleep(100);
  }
  throw new Error(`${what}: never seen`);
};

const ENV = { SOLARA_NATIVE_TOP_STRIP: "1" };
const sheets = !args.includes("--no-sheets");
const alerts = (from) => (existsSync(join(data, "activation.log")) ? readFileSync(join(data, "activation.log"), "utf8") : "").split("\n").slice(from).filter((l) => l.includes("alert (not shown):"));
const logLines = () => (existsSync(join(data, "activation.log")) ? readFileSync(join(data, "activation.log"), "utf8") : "").split("\n").length;
const sheet = async () => JSON.parse(await run(`return act("winfo");`));
const sheetKey = (info, chars, code) => run(`return C.devWindow(${info.sheetWindow}, "keys:0:${chars}:${code}");`);
const untilSheet = (what, want) => untilRun(what, async () => { const info = await sheet(); return want(info) ? info : null; }, 6000);
async function start(name, fixtureSession) {
  data = join(scratch, name);
  app = await launch(appPath, { data, port, session: fixtureSession, onboarded: true, env: ENV });
  rep.log(`${name}: pid ${app.pid}, data ${data}`);
  await sleep(1500);
  await run(`return act("fakeActiveClicks");`);
  if (sheets) assert.equal(await run(`return act("alertSheets:1");`), "1", "real sheets in this test instance");
}
async function stop() {
  await app.quit();
  app = null;
}
const stripTab = async (id) => {
  const deadline = Date.now() + 10000;
  let snap;
  while (Date.now() < deadline) {
    snap = await app.snapshot({ windowId: "w1", topStrip: true, fields: ["windows.topStrip"] }, { timeout: 2000 }).catch((error) => ({ error: error.message }));
    if (snap.windows?.[0]?.topStrip?.items?.items?.some((i) => i.kind === "tab")) break;
    await sleep(150);
  }
  const w = snap.windows?.[0];
  assert.ok(w?.topStrip?.items, `strip items: ${JSON.stringify(snap).slice(0, 600)}`);
  rep.log(`strip first item ${JSON.stringify(w.topStrip.items.items[0])}`);
  const item = w.topStrip.items.items.find((i) => i.kind === "tab" && (i.id === id || i.tabId === id || i.tabIds?.includes(id)));
  rep.log(`strip item ${id}: ${JSON.stringify(item)} strip ${JSON.stringify(w.topStrip.controls?.strip)}`);
  return { item, strip: w.topStrip.controls?.strip };
};

async function rows() {
  await start("rows", fixture);
  await assertSidebarPosition(app);
  await rep.check("the close button on a background row closes it and keeps the active tab", async () => {
    assert.equal(await run(`return closeButton("c");`), true);
    const v = await untilView("c closed", (v) => !v.tabs.includes("c"));
    assert.equal(v.shown, "a");
    await untilSnapshot("native c closed", (s) => !s.windows[0]?.tabIds.includes("c") && s.windows[0]?.selectedTabId === "a");
  });
  await rep.check("the close button on the active row hands over to the store's successor", async () => {
    const before = await run("return view();");
    assert.equal(await run(`return closeButton("a");`), true);
    const v = await untilView("a closed", (v) => !v.tabs.includes("a"));
    assert.ok(v.shown && v.shown !== "a" && before.tabs.includes(v.shown), `successor ${v.shown}`);
    await untilSnapshot("native successor", (s) => s.windows[0]?.selectedTabId === v.shown && !s.windows[0]?.tabIds.includes("a"));
    return `successor ${v.shown}`;
  });
  await rep.check("a middle click on a list row closes it", async () => {
    assert.equal(await run(`return middle("e");`), true);
    await untilView("e closed", (v) => !v.tabs.includes("e"));
    await untilSnapshot("native e closed", (s) => !s.windows[0]?.tabIds.includes("e"));
  });
  await rep.check("a middle click on an open pinned row unloads it and keeps it", async () => {
    assert.equal(await run(`return open("pr");`), "pr");
    await untilView("pr live", (v) => v.live.includes("pr"));
    assert.equal(await run(`return middle("pr");`), true);
    await untilView("pr unloaded by the middle click", (v) => v.tabs.includes("pr") && !v.live.includes("pr"));
    await sleep(300);
    assert.ok((await run("return view();")).tabs.includes("pr"), "pr stays");
    assert.equal(await run("return toast();"), null, "no toast for an unload");
  });
  await rep.check("a pinned row's close button unloads it, then removes it with an Undo toast that restores it", async () => {
    assert.equal(await run(`return open("pr");`), "pr");
    await untilView("pr live", (v) => v.live.includes("pr"));
    assert.equal(await run(`return closeButton("pr");`), true);
    await untilView("pr unloaded", (v) => v.tabs.includes("pr") && !v.live.includes("pr"));
    assert.equal(await run(`return closeButton("pr");`), true);
    await untilView("pr removed", (v) => !v.tabs.includes("pr"));
    assert.deepEqual(await run("return toast();"), { title: "Removed Pinned Tab", action: "Undo" });
    await run(`const t = ac.toasts.getState().toasts.w1; t.action.run(); return settle(600);`);
    const back = await run("return settle(400).then(() => restoredPin());");
    assert.equal(back.length, 1, `one restored pinned row: ${JSON.stringify(back)}`);
    await untilSnapshot("native pr back", (s) => s.windows[0]?.tabIds.includes(back[0]));
  });
  await rep.check("a middle click on a pinned tile unloads it and keeps it", async () => {
    assert.equal(await run(`return middle("p1");`), true);
    await untilView("p1 unloaded", (v) => v.tabs.includes("p1") && !v.live.includes("p1"));
    await untilSnapshot("native p1 kept", (s) => s.windows[0]?.tabIds.includes("p1"));
  });
  await rep.check("closing the last list tab beside pinned tabs keeps the window and asks nothing", async () => {
    await run(`st().updateSettings({ warnBeforeClosingLastTab: true, warnBeforeClosingWindow: true }); return settle(200);`);
    for (const id of ["d"]) {
      assert.equal(await run(`return closeButton("${id}");`), true);
      await untilView(`${id} closed`, (v) => !v.tabs.includes(id));
    }
    const left = await run("return view();");
    rep.log(`before the last list tab: ${JSON.stringify(left)}`);
    const last = await run(`const s = st(); return s.windows.w1.tabIds.filter((id) => s.tabs[id] && !s.tabs[id].pinned);`);
    for (const id of last) {
      assert.equal(await run(`return closeButton("${id}");`), true);
      await sleep(400);
      assert.equal((await sheet()).sheet, "", `no sheet while closing ${id}`);
    }
    const v = await untilView("a fresh tab beside the pinned ones", (v) => v.tabs.length >= 1 && !last.some((id) => v.tabs.includes(id)));
    assert.ok(await run(`return !!st().windows.w1;`), "the window stays");
    return JSON.stringify(v);
  });
  await stop();
}

async function strip() {
  await start("strip", stripFixture);
  await rep.check("the top strip's close button closes its tab", async () => {
    const { item, strip } = await stripTab("d");
    assert.ok(item && strip, "d is a strip tab");
    const left = item.windowX ?? item.x ?? item.frame?.[0], width = item.width ?? item.w ?? item.frame?.[2];
    const y = Math.round(strip[1] + strip[3] / 2), cx = Math.round(left + width - 6 - 10), hx = Math.round(left + width / 2);
    rep.log(`strip press at ${cx},${y} (hover ${hx})`);
    await run(`return point(${hx}, ${y}).then(() => act("mouse:moved:${hx},${y}")).then(() => settle(350)).then(() => point(${cx}, ${y})).then(() => act("mouse:moved:${cx},${y}")).then(() => settle(200)).then(() => press("", ${cx}, ${y})).then(() => settle(700));`);
    await untilView("d closed from the strip", (v) => !v.tabs.includes("d"));
    await untilSnapshot("native d closed", (s) => !s.windows[0]?.tabIds.includes("d"));
  });
  await rep.check("a middle click on a strip tab leaves it open", async () => {
    const { item, strip } = await stripTab("b");
    assert.ok(item && strip, "b is a strip tab");
    const left = item.windowX ?? item.x ?? item.frame?.[0], width = item.width ?? item.w ?? item.frame?.[2];
    const x = Math.round(left + width / 2), y = Math.round(strip[1] + strip[3] / 2);
    await run(`return point(${x}, ${y}).then(() => settle(250)).then(() => press("other", ${x}, ${y})).then(() => settle(900));`);
    const v = await run("return view();");
    rep.log(`after the strip middle click: ${JSON.stringify(v)}`);
    assert.ok(v.tabs.includes("b"), "b stays open");
    await untilSnapshot("native b kept", (s) => s.windows[0]?.tabIds.includes("b"));
  });
  await stop();
}

async function solo() {
  await start("solo", soloFixture);
  await rep.check("the last tab's close button asks first in a sheet on its window, a second press adds nothing, and Cancel keeps the tab", async () => {
    await run(`st().updateSettings({ warnBeforeClosingLastTab: true }); return settle(300);`);
    const profile = await run(`const s = st(); return s.profiles[s.windows.w1.profileId]?.name ?? null;`);
    assert.equal(await run(`return closeButton("solo");`), true);
    const info = await untilSheet("the close sheet", (i) => i.sheet);
    rep.log(`sheet ${JSON.stringify({ sheet: info.sheet, text: info.sheetText })}`);
    const text = info.sheetText.join(" | ");
    assert.ok(info.sheetText.includes("Close 1 tab?"), text);
    assert.ok(info.sheetText.includes(`This window has 1 tab open in your ${profile} profile.`), `profile ${profile}: ${text}`);
    for (const b of ["Close Tab", "Cancel", "Don’t ask me again"]) assert.ok(info.sheetText.includes(b), `${b}: ${text}`);
    await run(`return closeButton("solo");`);
    await sleep(500);
    assert.equal((await sheet()).sheetWindow, info.sheetWindow, "the same sheet after a second press");
    await sheetKey(info, "\\u001b", 53);
    await untilSheet("the sheet gone", (i) => !i.sheet);
    await sleep(800);
    assert.equal((await sheet()).sheet, "", "no second sheet after Cancel");
    assert.ok((await run("return view();")).tabs.includes("solo"), "Cancel keeps the tab");
    await untilSnapshot("native solo kept", (s) => s.windows[0]?.tabIds.includes("solo"));
    return `${info.sheetText.find((t) => t.startsWith("This window"))}`;
  });
  await rep.check("a tab opened while the sheet is up keeps the window: Close Tab then closes only the tab, and the next close asks again", async () => {
    assert.equal(await run(`return closeButton("solo");`), true);
    const info = await untilSheet("the close sheet", (i) => i.sheet);
    const added = await run(`return st().newTab("w1") ?? null;`);
    await untilRun("a second tab under the sheet", () => run(`return st().windows.w1.tabIds.length === 2 || null;`), 4000);
    await sheetKey(info, "\\r", 36);
    await untilRun("solo closed", () => run(`return !st().windows.w1?.tabIds.includes("solo") || null;`), 6000);
    await sleep(600);
    const left = await run(`return st().windows.w1?.tabIds ?? null;`);
    assert.equal(left?.length, 1, `one tab left: ${JSON.stringify(left)} (added ${added})`);
    assert.equal((await sheet()).sheet, "", "the window stayed without a sheet");
    assert.equal(await run(`return closeButton(${JSON.stringify(left[0])});`), true);
    const again = await untilSheet("the sheet asks again", (i) => i.sheet);
    await sheetKey(again, "\\u001b", 53);
    await untilSheet("the sheet gone again", (i) => !i.sheet);
    await untilSnapshot("native window kept", (s) => s.windows[0]?.tabIds.length === 1 && !s.windows[0].tabIds.includes("solo"));
  });
  await rep.check("Close Tab in the sheet closes the last tab and its window", async () => {
    const only = await run(`return st().windows.w1.tabIds[0];`);
    assert.equal(await run(`return closeButton(${JSON.stringify(only)});`), true);
    const info = await untilSheet("the close sheet again", (i) => i.sheet);
    await sheetKey(info, "\\r", 36);
    await untilRun("the window closed", () => run(`return !st().windows.w1;`), 10000);
  });
  await stop();
}

async function profiles() {
  await start("profiles", profilesFixture);
  await rep.check("closing a window's last tab of one profile asks with every profile's count, and Cancel keeps them", async () => {
    await run(`st().updateSettings({ warnBeforeClosingWindow: true, warnBeforeClosingLastTab: false }); return settle(300);`);
    const before = await run(`return st().windows.w1.tabIds;`);
    await run(`return expo.modules.SolaraApp.devWorkspaceMenuCommand("w1", "closeTab", null);`);
    const info = await untilSheet("the window sheet", (i) => i.sheet);
    const text = info.sheetText.join(" | ");
    rep.log(`window sheet ${text}`);
    assert.ok(info.sheetText.some((t) => /^Close \d+ tabs\?$/.test(t)), text);
    assert.ok(text.includes("Closing this window closes all tabs open across profiles:") && text.includes("in Personal") && text.includes("1 tab in Work"), text);
    assert.ok(info.sheetText.includes("Close All Tabs"), text);
    await sheetKey(info, "\\u001b", 53);
    await untilSheet("the window sheet gone", (i) => !i.sheet);
    assert.deepEqual(await run(`return st().windows.w1?.tabIds ?? null;`), before);
    return info.sheetText.find((t) => t.startsWith("Close "));
  });
  await rep.check("Move Tab to Profile asks in a sheet and Escape leaves the tab where it was", async () => {
    await run(`st().updateSettings({ warnBeforeMovingTabsToProfile: true }); st().activate("x"); return settle(400);`);
    await run(`return expo.modules.SolaraApp.devWorkspaceMenuCommand("w1", "moveTabToProfile", "work");`);
    const info = await untilSheet("the move sheet", (i) => i.sheet);
    const text = info.sheetText.join(" | ");
    rep.log(`move sheet ${text}`);
    for (const t of ["Move Tab to Profile?", "Moving tabs between profiles could result in some data being lost.", "Move Tab", "Cancel", "Don't warn me again"]) assert.ok(info.sheetText.includes(t), `${t}: ${text}`);
    await sheetKey(info, "\\u001b", 53);
    await untilSheet("the move sheet gone", (i) => !i.sheet);
    await sleep(500);
    assert.deepEqual(await run(`const t = st().tabs.x; return [t.windowId, t.profileId];`), ["w1", "default"]);
    await untilSnapshot("native x unmoved", (s) => s.tabs.find((t) => t.id === "x")?.profileId === "default");
  });
  await stop();
}

async function profilesWithSibling() {
  await start("profiles-sibling", profilesWithSiblingFixture);
  await rep.check("closing a profile's tab while that profile has another in the window asks nothing and keeps the window", async () => {
    await run(`st().updateSettings({ warnBeforeClosingWindow: true, warnBeforeClosingLastTab: true }); st().activate("x"); return settle(400);`);
    await run(`return expo.modules.SolaraApp.devWorkspaceMenuCommand("w1", "closeTab", null);`);
    await untilRun("x closed", () => run(`return !st().windows.w1?.tabIds.includes("x") || null;`), 6000);
    await sleep(600);
    assert.equal((await sheet()).sheet, "", "no sheet");
    assert.deepEqual(await run(`return st().windows.w1?.tabIds.filter((id) => id !== "x") ?? null;`), ["o", "m"]);
    await untilSnapshot("native x closed, window kept", (s) => s.windows[0]?.tabIds.includes("m") && !s.windows[0].tabIds.includes("x"));
  });
  await stop();
}

try {
  await rows();
  await strip();
  if (sheets) {
    await solo();
    await profiles();
    await profilesWithSibling();
  }
} finally {
  await app?.quit();
  server.close();
  if (!keep) rmSync(scratch, { recursive: true, force: true });
  else rep.say(`data: ${scratch}`);
}
process.exit(rep.summary() ? 0 : 1);

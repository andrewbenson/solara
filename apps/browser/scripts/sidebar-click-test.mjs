import assert from "node:assert/strict";
import { mkdtempSync, rmSync } from "node:fs";
import { createServer } from "node:http";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { launch, reporter, session, sleep } from "../../../scripts/lib/instance.mjs";
import { fixturePage } from "../../../scripts/lib/fixture-html.mjs";

const args = process.argv.slice(2);
const appArg = args.find((a) => !a.startsWith("--"));
if (!appArg) {
  console.error("usage: node sidebar-click-test.mjs <Debug Solara.app> [--port=<DevTools port>] [--keep-data]\n\nOne click on a sidebar tab or pinned tile opens it, through AppKit's event path: as its hover card appears, under another tile's appearing card, after a New Tab and after closing a pinned tab.");
  process.exit(2);
}
const appPath = resolve(appArg);
const port = args.find((a) => a.startsWith("--port="))?.slice(7);
const keep = args.includes("--keep-data");
if (keep) process.env.AC_KEEP_DATA = "1";
const scratch = mkdtempSync(join(tmpdir(), "ac-sidebar-click-"));
const data = join(scratch, "data");
const rep = reporter(join(scratch, "sidebar-click-test.log"), { name: "sidebar-click-test" });

const server = createServer((req, res) => {
  const name = req.url.slice(1) || "root";
  res.writeHead(200, { "content-type": "text/html" });
  res.end(fixturePage(name, { bodyStyle: "font:40px sans-serif" }));
});
await new Promise((r) => server.listen(0, "127.0.0.1", r));
const url = (name) => `http://127.0.0.1:${server.address().port}/${name}`;
const tab = (id, extra = {}) => ({ id, url: url(id), title: id.toUpperCase(), ...extra });
const fixture = session({
  windows: [{ id: "w1", frame: [80, 80, 1280, 800], activeTabIds: { default: "a" } }],
  tabs: [
    tab("p1", { pinned: true, pinnedUrl: url("p1") }),
    tab("p2", { pinned: true, pinnedUrl: url("p2") }),
    tab("pr", { pinned: true, pinnedUrl: url("pr"), pinnedAsRow: true }),
    tab("a"), tab("b"), tab("c"),
  ],
});

let app = null;
const HELPERS = `
const C = globalThis.expo.modules.SolaraCEF;
const st = () => ac.store.getState();
const settle = (ms) => new Promise((r) => setTimeout(r, ms));
const win = () => C.chromeWindows().then((ws) => ws.find((w) => w.hasRoot).window);
const act = (a) => win().then((n) => C.devWindow(n, a));
const shown = () => st().windows.w1.activeTabIds[st().windows.w1.profileId];
const center = (id) => new Promise((r) => {
  const item = [...globalThis.sidebarDrag.items.values()].find((i) => i.view && i.tabIds.includes(id));
  item ? item.view.measureInWindow((x, y, w, h) => r([Math.round(x + Math.min(w / 2, 60)), Math.round(y + h / 2)]))
    : ac.sidebarRows.measureRow("w1", id).then((f) => r(f ? [Math.round(f.x + Math.min(f.width / 2, 60)), Math.round(f.y + f.height / 2)] : null));
});
const point = (x, y) => ac.shell.devSetPointer("w1", { x, y });
const click = (x, y) => act("mouse:down:" + x + "," + y).then(() => settle(70)).then(() => act("mouse:up:" + x + "," + y));
const clickTab = (id) => center(id).then(([x, y]) => point(x, y).then(() => click(x, y))).then(() => settle(450)).then(() => shown());
const clickAsCardMounts = (hoverId, clickId) => Promise.all([center(hoverId), center(clickId), win()]).then(([[hx, hy], [cx, cy], n]) =>
  point(700, 500).then(() => settle(400)).then(() => new Promise((done) => {
    const fadeMs = ac.sidebarHover.HOVER_CARD_FADE_MS;
    let stop = ac.sidebarRows.useSidebarUi.subscribe((u) => {
      if (!u.hover || !stop) return;
      stop();
      stop = null;
      const before = shown();
      if (u.hover.id !== hoverId) return done({ card: u.hover.id, before, shown: before });
      const set = Date.now();
      C.devWindow(n, "mouse:down:" + cx + "," + cy).then((hit) => {
        const downMs = Date.now() - set;
        return settle(70).then(() => C.devWindow(n, "mouse:up:" + cx + "," + cy)).then(() => settle(450))
          .then(() => done({ card: u.hover.id, before, downMs, fading: downMs < fadeMs, hit, shown: shown() }));
      });
    });
    point(hx, hy);
    setTimeout(() => { if (stop) { stop(); stop = null; done({ card: null, before: shown(), shown: shown() }); } }, 2500);
  })));
`;
const run = (body) => app.eval(`${HELPERS}\n${body}`, { timeout: 20000 });
const press = (key, keyCode) => run(`return ac.shell.devKeyEquivalent("w1", ${JSON.stringify({ key, keyCode, modifiers: ["command"] })});`);
const clickTab = (id) => run(`return clickTab(${JSON.stringify(id)});`);

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
const selectedByNative = async (id) => {
  const state = await untilSnapshot(`native selected tab ${id}`, (state) => state.windows[0]?.selectedTabId === id);
  assert.ok(state.windows[0].tabIds.includes(id), `${id} belongs to the native window`);
};

async function asCardMounts(hoverId, clickId, rounds) {
  const misses = [];
  let clicked = 0;
  for (let tries = 0; clicked < rounds && tries < rounds * 4; tries++) {
    assert.equal(await clickTab("c"), "c", "c opens before each round");
    await selectedByNative("c");
    const r = await run(`return clickAsCardMounts(${JSON.stringify(hoverId)}, ${JSON.stringify(clickId)});`);
    rep.log(`${hoverId} -> ${clickId}: ${JSON.stringify(r)}`);
    if (r.card !== hoverId || r.before === clickId || !r.fading) continue;
    clicked++;
    if (r.shown !== clickId) misses.push(r.shown);
    if (r.shown === clickId) await selectedByNative(clickId);
  }
  assert.equal(clicked, rounds, `a click reached ${clickId} while ${hoverId}'s card faded in on ${clicked} of ${rounds} rounds`);
  assert.deepEqual(misses, [], `${misses.length} of ${rounds} clicks on ${clickId} did nothing`);
  return `${rounds} clicks`;
}

try {
  app = await launch(appPath, { data, port, session: fixture, onboarded: true });
  rep.log(`instance: pid ${app.pid}, DevTools port ${app.port}, data ${data}`);
  await sleep(1500);
  await run(`return act("fakeActiveClicks");`);

  for (const id of ["p1", "p2", "pr", "a"])
    await rep.check(`a click on ${id} in the frame its hover card appears opens it`, () => asCardMounts(id, id, 4));
  await rep.check("a click on p2 while p1's card fades in over it opens p2", () => asCardMounts("p1", "p2", 4));

  await rep.check("after a New Tab, each tab opens on its first click", async () => {
    await clickTab("a");
    await press("t", 17);
    await sleep(600);
    for (const id of ["b", "a", "p1", "pr", "c"]) {
      assert.equal(await clickTab(id), id, `${id} after a New Tab`);
      await selectedByNative(id);
    }
  });

  await rep.check("a closed pinned tab opens on its first click", async () => {
    for (const id of ["p1", "pr"]) {
      assert.equal(await clickTab(id), id);
      await selectedByNative(id);
      await press("w", 13);
      await sleep(600);
      assert.notEqual(await run("return shown();"), id, `${id} closed`);
      await untilSnapshot(`native ${id} closed`, (state) => state.windows[0]?.selectedTabId !== id && state.windows[0]?.tabIds.includes(id));
      assert.equal(await clickTab("b"), "b");
      await selectedByNative("b");
      assert.equal(await clickTab(id), id, `${id} after closing it`);
      await selectedByNative(id);
    }
  });
} finally {
  await app?.quit();
  server.close();
  if (!keep) rmSync(data, { recursive: true, force: true });
  else rep.say(`data: ${data}`);
}
process.exit(rep.summary() ? 0 : 1);

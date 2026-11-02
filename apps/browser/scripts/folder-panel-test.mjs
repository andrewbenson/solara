#!/usr/bin/env node
import assert from "node:assert/strict";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { launch, reporter, sleep } from "../../../scripts/lib/instance.mjs";

let nativePollDeadline = null;
const evaluate = (body, options = {}) => {
  if (nativePollDeadline !== null && nativePollDeadline - Date.now() < 1000) throw new Error("native comparison has less than 1000 ms left");
  return app.eval(body, { ...options, ...(nativePollDeadline === null ? {} : { timeout: 1000 }) });
};
const acceptSnapshot = async (deadline, accept, ...args) => {
  const previous = nativePollDeadline;
  nativePollDeadline = previous === null ? deadline : Math.min(previous, deadline);
  try {
    return await accept(...args);
  } finally {
    nativePollDeadline = previous;
  }
};

const args = process.argv.slice(2);
const appArg = args.find((a) => !a.startsWith("--"));
if (!appArg || resolve(appArg).startsWith("/Applications/")) {
  console.error("usage: node folder-panel-test.mjs <Debug Solara.app under apps/browser/build-*> [--keep-data]");
  process.exit(2);
}
const keep = args.includes("--keep-data");
const scratch = mkdtempSync(join(tmpdir(), "ac-folder-panel-"));
const rep = reporter(join(scratch, "folder-panel-test.log"), { name: "folder-panel-test" });

let app;
async function run() {
  const data = join(scratch, "native");
  app = await launch(resolve(appArg), { data, onboarded: true });
  try {
    await app.ready({ test: "return !!globalThis.expo?.modules?.SolaraPages?.devViewFrame && !!ac.pages.tileFolders" });
    await sleep(4000);
    const win = await evaluate(`return globalThis.expo.modules.SolaraCEF.chromeWindows().then((ws) => ws.find((w) => w.hasRoot).window)`);
    const dev = (action) => evaluate(`return globalThis.expo.modules.SolaraCEF.devWindow(${win}, ${JSON.stringify(action)})`);
    await dev("fakeActiveClicks");
    const setup = JSON.parse(await evaluate(`const s = ac.store.getState(); const w = Object.keys(s.windows)[0];
      const ids = ["one", "two", "three"].map((n) => s.newTab(w, { url: "data:text/html,<title>" + n + "</title>" + n, background: true }));
      s.pinTabs(ids, true);
      return new Promise((r) => setTimeout(r, 800)).then(() => JSON.stringify({ w, ids, folder: ac.pages.tileFolders.make(ids) }))`));
    assert.ok(setup.folder, "a folder made");
    await sleep(1200);
    const q = JSON.stringify;
    const anchor = async () => JSON.parse(await evaluate(`return ac.pages.tileFolders.measure(${q(setup.w)}, ${q(setup.folder)}).then((a) => JSON.stringify(a))`));
    const isOpen = () => evaluate(`return !!ac.pages.tileFolders.panel.getState().open`);
    const nativePanel = (state) => state.windows.find((window) => window.id === setup.w)?.folderPanel;
    const untilSnapshot = async (what, accept, ms = 5000) => {
      const end = Date.now() + ms;
      let last;
      while (Date.now() < end) {
        if (!app.alive) throw new Error(`${what}: app exited`);
        if (Math.min(end, nativePollDeadline ?? Infinity) - Date.now() < 1000) break;
        last = await app.snapshot({ windowId: setup.w, tabDrag: true }, { timeout: 1000 }).catch((error) => ({ error: error.message }));
        if (Date.now() < end && !last.error && last.consistent && await acceptSnapshot(end, accept, last) && Date.now() < end) return last;
        await sleep(100);
      }
      throw new Error(`${what}: native snapshot never matched (${JSON.stringify(last)})`);
    };
    const nativeClosed = async (what) => {
      await untilSnapshot(what, async (state) => !nativePanel(state) && !(await isOpen()));
    };
    const active = () => evaluate(`const s = ac.store.getState(); const w = s.windows[${q(setup.w)}]; return w.activeTabIds[w.profileId]`);
    const press = async (x, y) => {
      await dev(`mouse:down:${x},${y}`);
      await sleep(60);
      await dev(`mouse:up:${x},${y}`);
    };
    const clickTile = async () => {
      const tile = await anchor();
      assert.ok(tile, "the folder tile is laid out");
      await press(tile.x + tile.width / 2, tile.y + tile.height / 2);
    };
    const rowFrames = async () => {
      const rows = [];
      for (let i = 0; i < 3; i++) rows.push(JSON.parse(await evaluate(`return globalThis.expo.modules.SolaraPages.devViewFrame(${win}, "FolderPanelRow#${i}")`)));
      return rows.filter((r) => r.found).map(({ x, y, width, height }) => ({ x, y, width, height }));
    };
    const out = {};
    const openedPanel = async (what) => {
      await untilSnapshot(what, async (state) => {
        out.opened = await isOpen();
        out.rows = await rowFrames();
        const tile = await anchor();
        const sidebar = JSON.parse(await evaluate(`return globalThis.expo.modules.SolaraPages.devViewFrame(${win}, "SidebarFolderPanelView")`));
        out.native = sidebar.found;
        const panel = nativePanel(state);
        const window = state.windows.find((item) => item.id === setup.w);
        const card = window?.sidebarDrag?.folderPanel;
        if (!window || !tile || !sidebar.found || !card || panel?.folderId !== setup.folder || panel.rows.length !== 3 || out.rows.length !== 3 || !out.opened || panel.visible !== out.opened) return false;
        const titlebar = window.frame.height - window.contentFrame.height;
        assert.ok(Number.isFinite(titlebar), "the window titlebar height is measured");
        assert.ok(sidebar.width > 12 && tile.width > 0 && tile.height > 0 && card.w > 0 && card.h > 0, "the sidebar, tile and card have visible frames");
        assert.ok(Math.abs(card.x - sidebar.x - 6) <= 0.5, "the card is 6 pt inside the sidebar");
        assert.ok(Math.abs(card.y - tile.y - tile.height - 6) <= 0.5, "the card is 6 pt below the tile");
        assert.ok(Math.abs(card.w - Math.max(0, sidebar.width - 12)) <= 0.5, "the card width is the sidebar width minus 12 pt");
        for (let i = 0; i < panel.rows.length; i++) {
          const row = { ...out.rows[i], y: out.rows[i].y - titlebar };
          for (const [index, key] of ["x", "y", "width", "height"].entries()) {
            assert.ok(Math.abs(panel.rows[i][index] - row[key]) <= 0.5, `native row ${i} ${key} differs from the window measurement`);
          }
          assert.ok(Math.abs(row.x - card.x - 6.5) <= 0.5, `row ${i} is 6.5 pt inside the card`);
          assert.ok(Math.abs(row.width - (card.w - 13)) <= 0.5, `row ${i} width is the card width minus 13 pt`);
          if (i === panel.rows.length - 1) assert.ok(Math.abs(card.y + card.h - row.y - row.height - 9.5) <= 0.5, "the last row is 9.5 pt above the card bottom");
          assert.ok(row.x >= card.x - 0.5 && row.y >= card.y - 0.5 && row.x + row.width <= card.x + card.w + 0.5 && row.y + row.height <= card.y + card.h + 0.5, `row ${i} is inside the card`);
        }
        return true;
      });
      return out.opened;
    };
    await clickTile();
    await sleep(700);
    await openedPanel("native folder panel");
    if (out.rows[1]) await press(out.rows[1].x + out.rows[1].width / 2, out.rows[1].y + out.rows[1].height / 2);
    await sleep(500);
    out.rowShows = (await active()) === setup.ids[1];
    out.rowCloses = !(await isOpen());
    {
      const snapshot = await untilSnapshot("row selects a tab and closes the native panel", async (state) =>
        !nativePanel(state) && !(await isOpen()) && state.windows.find((window) => window.id === setup.w)?.selectedTabId === await active()
          && state.windows.find((window) => window.id === setup.w)?.selectedTabId === setup.ids[1]);
      assert.equal(snapshot.windows.find((window) => window.id === setup.w)?.selectedTabId, setup.ids[1]);
    }
    await clickTile();
    await sleep(700);
    out.openedAgain = await openedPanel("native folder panel reopened before page click");
    await press(800, 500);
    await sleep(500);
    out.pageCloses = !(await isOpen());
    await nativeClosed("page click closes the native panel");
    await clickTile();
    await sleep(700);
    const reopened = await openedPanel("native folder panel reopened before tile click");
    await clickTile();
    await sleep(700);
    out.tileCloses = reopened && !(await isOpen());
    await nativeClosed("tile click closes the native panel");
    await clickTile();
    await sleep(700);
    await openedPanel("native folder panel reopened before Escape");
    await dev("keys:0:\u001b:53");
    await sleep(500);
    out.escCloses = !(await isOpen());
    await nativeClosed("Escape closes the native panel");
    rep.say(`native: ${JSON.stringify(out)}`);
    return out;
  } finally {
    await app.quit();
    if (!keep) rmSync(data, { recursive: true, force: true });
  }
}

await rep.check("a native folder tile opens the panel; a row selects its tab; the page, tile and Escape close it", async () => {
  const panel = await run();
  assert.ok(panel.native, "a SidebarFolderPanelView");
  assert.ok(panel.opened, "opened");
  assert.equal(panel.rows.length, 3, "three member rows");
  for (let i = 0; i < panel.rows.length; i++) {
    assert.ok(panel.rows[i].width > 0, `row ${i} has a visible frame`);
    assert.ok(Math.abs(panel.rows[i].height - 34) <= 0.5, `row ${i} is 34 pt high`);
    if (i > 0) {
      assert.ok(Math.abs(panel.rows[i].y - panel.rows[i - 1].y - 37) <= 0.5, "member rows have a 37 pt pitch");
      assert.ok(Math.abs(panel.rows[i].x - panel.rows[0].x) <= 0.5 && Math.abs(panel.rows[i].width - panel.rows[0].width) <= 0.5, "member rows share the panel's column");
    }
  }
  for (const key of ["rowShows", "rowCloses", "openedAgain", "pageCloses", "tileCloses", "escCloses"]) assert.equal(panel[key], true, key);
});
process.exit(rep.summary() ? 0 : 1);

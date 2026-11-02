import { isDeepStrictEqual } from "node:util";
import { mkdtempSync, rmSync } from "node:fs";
import { createServer } from "node:http";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { launch, reporter, session, sleep } from "../../../scripts/lib/instance.mjs";

const args = process.argv.slice(2);
const appArg = args.find((a) => !a.startsWith("--"));
if (!appArg) {
  console.error(`usage: node close-selection-test.mjs <Debug Solara.app> [--keep-data]

⌘W with several tabs selected in the sidebar, through a real key press on the window: the File menu's item reads
"Close 3 Tabs", the press closes all 3 selected tabs (not just the active one) and clears the selection, and one
⇧⌘T brings all 3 back in their places. Then, with a New Tab among the selection so the close would take the window,
⌘W asks once (SolaraShell.confirm, stubbed to count calls and answer Cancel) and cancelling closes nothing. The sidebar is native.`);
  process.exit(2);
}
const keep = args.includes("--keep-data");
const scratch = mkdtempSync(join(tmpdir(), "ac-close-selection-"));
const rep = reporter(join(scratch, "close-selection-test.log"), { name: "close-selection-test" });

const server = createServer((req, res) => {
  res.writeHead(200, { "content-type": "text/html" });
  res.end(`<!doctype html><title>${req.url.slice(1).toUpperCase()}</title><link rel="icon" href="data:,"><body>${req.url.slice(1)}</body>`);
});
await new Promise((r) => server.listen(0, "127.0.0.1", r));
const url = (n) => `http://127.0.0.1:${server.address().port}/${n}`;
const names = ["a", "b", "c", "d", "e"];
const fixture = session({
  windows: [{ id: "w1", frame: [80, 80, 1280, 800], activeTabIds: { default: "c" } }],
  tabs: names.map((id) => ({ id, url: url(id), title: id.toUpperCase() })),
  settings: { warnBeforeClosingLastTab: false, warnBeforeClosingWindow: false },
});

const K = (key, keyCode, ...modifiers) => ({ key, keyCode, modifiers: ["command", ...modifiers], focus: "window" });
let app = null;
let nativePollDeadline = 0;
const run = (body, timeout = 20000) => {
  if (nativePollDeadline) {
    if (nativePollDeadline - Date.now() < 1000) throw new Error("native comparison has less than 1000 ms remaining");
    timeout = Math.min(timeout, 1000);
  }
  return app.eval(body, { timeout });
};
const press = (key, extra = {}) => run(`return ac.shell.devKeyEquivalent("w1", ${JSON.stringify({ ...key, ...extra })});`);
const titles = `const s = ac.store.getState(); return s.windows.w1.tabIds.map((id) => s.tabs[id].title || s.tabs[id].url.split("/").pop().toUpperCase());`;
const untilSnapshot = async (what, accept, ms = 5000) => {
  const deadline = Date.now() + ms;
  let last;
  while (Date.now() < deadline) {
    if (!app.alive) throw new Error(`${what}: the owned app exited`);
    if (deadline - Date.now() < 1000) break;
    last = await app.snapshot({ windowId: "w1" }, { timeout: 1000 }).catch((error) => ({ error: error.message }));
    nativePollDeadline = deadline;
    try {
      if (!last.error && last.consistent && Date.now() < deadline && await accept(last) && Date.now() < deadline) return last;
    } finally {
      nativePollDeadline = 0;
    }
    await sleep(100);
  }
  throw new Error(`${what}: native snapshot never matched (${JSON.stringify(last)})`);
};
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

const modes = [
  ["native-sidebar", {}],
];
try {
  for (const [tag, env] of modes) {
    app = await launch(resolve(appArg), {
      data: join(scratch, `data-${tag}`), fresh: true, session: fixture, onboarded: true, probe: true, env,
      ready: "return !!ac.store.getState().windows.w1 && ac.store.getState().windows.w1.tabIds.length === 5",
    });
    await until("pages titled", `return (() => { ${titles} })().join() === "A,B,C,D,E" || null;`, 15000);
    await rep.check(`${tag}-menu-reads-close-3-tabs`, async () => {
      await run(`ac.store.getState().setSelection("w1", ["b", "c", "e"]); return true;`);
      await sleep(300);
      const dry = await press(K("w", 13), { dry: true });
      const title = dry?.fired?.[0]?.title;
      if (title !== "Close 3 Tabs") throw new Error(`⌘W's item reads ${JSON.stringify(title)}: ${JSON.stringify(dry)}`);
      const native = await untilSnapshot("native selection before close", (state) => {
        const window = state.windows.find((entry) => entry.id === "w1");
        return isDeepStrictEqual(window?.tabIds, names) && state.tabs.length === names.length &&
          isDeepStrictEqual(window.tabIds.map((id) => state.tabs.find((tab) => tab.id === id)?.title), names.map((id) => id.toUpperCase()));
      });
      const window = native.windows.find((entry) => entry.id === "w1");
      if (window.selectedTabId !== "c") throw new Error(`native selected tab ${window.selectedTabId}`);
      return title;
    });
    await rep.check(`${tag}-cmd-w-closes-the-selection`, async () => {
      await press(K("w", 13));
      let left = await until("3 closed", `return (() => { ${titles} })().length === 2 ? (() => { ${titles} })() : null;`);
      if (left.join() !== "A,D") throw new Error(`left ${left}`);
      const selection = await run(`return ac.store.getState().selection.w1 ?? [];`);
      if (selection.length) throw new Error(`selection not cleared: ${selection}`);
      const native = await untilSnapshot("native three tabs closed", async (state) => {
        left = await run(titles);
        if (!isDeepStrictEqual(left, ["A", "D"])) throw new Error(`left ${left}`);
        const window = state.windows.find((entry) => entry.id === "w1");
        return isDeepStrictEqual(window?.tabIds, ["a", "d"]) && isDeepStrictEqual(state.tabs.map((tab) => tab.id), ["a", "d"]) &&
          isDeepStrictEqual(window.tabIds.map((id) => state.tabs.find((tab) => tab.id === id)?.title), left);
      });
      const nativeTitles = native.windows[0].tabIds.map((id) => native.tabs.find((tab) => tab.id === id)?.title);
      if (!isDeepStrictEqual(nativeTitles, left)) throw new Error(`native titles ${nativeTitles} vs JS ${left}`);
      return left;
    });
    await rep.check(`${tag}-shift-cmd-t-reopens-all-3`, async () => {
      await press(K("t", 17, "shift"));
      let back = await until("5 tabs", `return (() => { ${titles} })().length === 5 ? (() => { ${titles} })() : null;`);
      if (back.join() !== "A,B,C,D,E") throw new Error(`back ${back}`);
      const closed = await run(`return ac.store.getState().closedTabs.length;`);
      if (closed) throw new Error(`${closed} still in Recently Closed`);
      let backIds;
      const native = await untilSnapshot("native tabs restored in order", async (state) => {
        back = await run(titles);
        if (!isDeepStrictEqual(back, ["A", "B", "C", "D", "E"])) throw new Error(`back ${back}`);
        backIds = await run(`return ac.store.getState().windows.w1.tabIds;`);
        return isDeepStrictEqual(state.windows[0]?.tabIds, backIds) && isDeepStrictEqual(state.windows[0].tabIds.map((id) => state.tabs.find((tab) => tab.id === id)?.title), back);
      });
      const nativeTitles = native.windows[0].tabIds.map((id) => native.tabs.find((tab) => tab.id === id)?.title);
      if (!isDeepStrictEqual(nativeTitles, back)) throw new Error(`native titles ${nativeTitles} vs JS ${back}`);
      return back;
    });
    await rep.check(`${tag}-closing-the-window-asks-once`, async () => {
      await run(`const s = ac.store.getState(); s.updateSettings({ warnBeforeClosingLastTab: true }); s.newTab("w1"); return true;`);
      const ids = await until("a New Tab", `const s = ac.store.getState(), w = s.windows.w1; return w.tabIds.length === 6 ? w.tabIds : null;`);
      await run(`const M = globalThis.expo.modules.SolaraShell; globalThis.__asked = []; M.confirm = (o) => { globalThis.__asked.push(o.title ?? ""); return Promise.resolve({ confirmed: false, suppressed: false }); }; ac.store.getState().setSelection("w1", ${JSON.stringify(ids)}); return true;`);
      await sleep(300);
      await press(K("w", 13));
      await sleep(800);
      const asked = await run(`return globalThis.__asked;`);
      if (asked.length !== 1) throw new Error(`asked ${asked.length} times: ${JSON.stringify(asked)}`);
      let left = await run(`return ac.store.getState().windows.w1?.tabIds.length ?? 0;`);
      if (left !== 6) throw new Error(`cancel left ${left} tabs`);
      await untilSnapshot("native cancel keeps every tab", async (state) => {
        left = await run(`return ac.store.getState().windows.w1?.tabIds.length ?? 0;`);
        return isDeepStrictEqual(state.windows[0]?.tabIds, ids) && state.tabs.length === left;
      });
      return asked[0];
    });
    await app.quit();
    app = null;
  }
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

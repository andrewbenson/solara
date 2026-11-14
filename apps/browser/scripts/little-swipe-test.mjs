import assert from "node:assert/strict";
import { mkdtempSync, writeFileSync } from "node:fs";
import { createServer } from "node:http";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { launch, reporter, session, sleep } from "../../../scripts/lib/instance.mjs";
import { fixturePage } from "../../../scripts/lib/fixture-html.mjs";

const args = process.argv.slice(2);
const appPath = args.find((arg) => !arg.startsWith("--"));
if (!appPath) throw new Error("usage: node little-swipe-test.mjs <Debug app> [--native] [--keep-data]");
const wantsNative = args.includes("--native");
const scratch = mkdtempSync(join(tmpdir(), "ac-little-swipe-"));
const rep = reporter(join(scratch, "little-swipe-test.log"), { name: "little-swipe-test" });
const server = createServer((request, response) => {
  response.writeHead(200, { "content-type": "text/html" });
  response.end(fixturePage(request.url.slice(1)));
});
await new Promise((resolve) => server.listen(0, "127.0.0.1", resolve));
const url = (page) => `http://127.0.0.1:${server.address().port}/${page}`;
let app;
const run = (body) => app.eval(body, { timeout: 20000 });
const until = async (body, milliseconds = 15000) => {
  const end = Date.now() + milliseconds;
  while (Date.now() < end) {
    if (!app.alive) throw new Error("Little swipe instance exited");
    const result = await run(body);
    if (result) return result;
    await sleep(100);
  }
  throw new Error(`timed out: ${body}`);
};
try {
  app = await launch(resolve(appPath), {
    data: join(scratch, "data"), fresh: true, onboarded: true, probe: true,
    session: session({ windows: [{ id: "w1" }], tabs: [{ id: "a", url: url("main") }], settings: { warnBeforeClosingLastTab: false, warnBeforeClosingWindow: false } }),
    ready: "return !!ac.store.getState().windows.w1 && !!globalThis.acSwipe;",
  });
  const windowId = await run(`return ac.store.getState().createWindow({ small: true, url: ${JSON.stringify(url("one"))} });`);
  const tabId = await until(`return ac.store.getState().windows[${JSON.stringify(windowId)}]?.tabIds[0];`);
  const readTitle = `ac.store.getState().tabs[${JSON.stringify(tabId)}]?.title`;
  await until(`return ${readTitle} === "ONE";`);
  for (const name of ["two", "three"]) {
    await run(`ac.store.getState().navigate(${JSON.stringify(tabId)}, ${JSON.stringify(url(name))}, { userInitiated: true }); return true;`);
    await until(`return ${readTitle} === ${JSON.stringify(name.toUpperCase())};`);
  }
  await sleep(600);
  const helpers = `
    const tabId = ${JSON.stringify(tabId)};
    const windowId = ${JSON.stringify(windowId)};
    const hostOf = (fiber) => { let f = fiber; while (f && !(f.stateNode && f.stateNode.measureInWindow)) f = f.child; return f?.stateNode; };
    const measure = (fiber) => new Promise((resolve) => { const node = hostOf(fiber); return node ? node.measureInWindow((...rect) => resolve(rect)) : resolve(null); });
    const overlay = () => acPerf.findFibers("SwipeOverlay", 500).find((f) => f.memoizedProps.tabId === tabId);
    const sample = () => {
      const own = overlay();
      return Promise.all([measure(own.child), globalThis.expo.modules.SolaraMedia.describePaneOverlays(windowId)]).then(([area, raw]) => {
        const native = JSON.parse(raw)?.tabs?.[tabId]?.swipe ?? null;
        return (!native && own.child.sibling ? measure(own.child.sibling) : Promise.resolve(null)).then((rn) => ({ area, native, rn,
          lists: acPerf.findFibers("DestinationList", 100).filter((f) => f.memoizedProps.tabId === tabId).length }));
      });
    };
  `;
  const pushes = Array.from({ length: 8 }, (_, i) => ({ phase: "changed", dx: 20, dy: 0, timestampMs: (i + 1) * 16 }));
  const kept = [{ phase: "began", dx: 0, dy: 0, timestampMs: 0 }, ...pushes, ...Array.from({ length: 6 }, (_, i) => ({ phase: "changed", dx: 1, dy: 0, timestampMs: 200 + i * 100 })), { phase: "cancelled", dx: 0, dy: 0, timestampMs: 760 }];
  const held = [{ phase: "began", dx: 0, dy: 0, timestampMs: 0 }, ...pushes, { phase: "ended", dx: 0, dy: 0, timestampMs: 1100 }];
  for (const step of [...kept, ...held]) step.atMs = step.timestampMs;
  for (const [name, steps, at, size] of [["capsule", kept, 620, [82, 82]], ["list", held, 950, [200, 92]]]) {
    await rep.check(`little-${name}`, async () => {
      const capture = join(scratch, `${name}.png`);
      const state = await run(`${helpers}
        return new Promise((resolve, reject) => {
          let sampled;
          setTimeout(() => sample().then((value) => ac.shell.devSnapshotWindow(windowId, ${JSON.stringify(capture)}).then((written) => { sampled = { ...value, snapshot: written }; })).catch(reject), ${at});
          globalThis.acSwipe.pane(tabId).devSimulate(${JSON.stringify(steps)}, { ignorePreference: true }).then(() => setTimeout(() => resolve(sampled), 150), reject);
        });`);
      assert.ok(state && state.snapshot, `snapshot failed: ${JSON.stringify(state)}`);
      const frame = state.native?.frame ?? state.rn;
      assert.ok(frame, `capsule absent: ${JSON.stringify(state)}`);
      assert.ok(frame.slice(2).every((value, i) => Math.abs(value - size[i]) <= 0.5), `size ${frame}`);
      const offset = name === "capsule" ? -41 : -27;
      assert.ok(Math.abs(frame[1] - (state.area[1] + state.area[3] / 2 + offset)) <= 0.5, `centre ${JSON.stringify(state)}`);
      if (wantsNative) {
        assert.ok(state.native, "Little Solara must host the native capsule");
        assert.equal(state.lists, 0);
        assert.equal(state.rn, null);
      }
      await sleep(400);
      assert.equal(await run(`return ${readTitle};`), name === "capsule" ? "THREE" : "TWO");
      writeFileSync(join(scratch, `${name}.json`), JSON.stringify(state, null, 2));
      return state;
    });
  }
  if (wantsNative) await rep.check("little-new-tab-destination", async () => {
    const markWindow = await run(`return ac.store.getState().createWindow({ small: true });`);
    const markTab = await until(`return ac.store.getState().windows[${JSON.stringify(markWindow)}]?.tabIds[0];`);
    await run(`ac.store.getState().closePanel(${JSON.stringify(markWindow)}); return true;`);
    await sleep(300);
    for (const name of ["one", "two"]) {
      await run(`ac.store.getState().navigate(${JSON.stringify(markTab)}, ${JSON.stringify(url(name))}, { userInitiated: true }); return true;`);
      await until(`return ac.store.getState().tabs[${JSON.stringify(markTab)}]?.title === ${JSON.stringify(name.toUpperCase())};`);
    }
    const entries = await run(`return globalThis.acSwipe.history.items(${JSON.stringify(markTab)}, -1);`);
    assert.deepEqual(entries.map((entry) => entry.title), ["ONE", "New Tab"]);
    const steps = [{ phase: "began", dx: 0, dy: 0, atMs: 0 }, ...pushes,
      { phase: "changed", dx: 0, dy: 75, atMs: 850 }, { phase: "ended", dx: 0, dy: 0, atMs: 1300 }].map((step) => ({ ...step, timestampMs: step.atMs }));
    const markHelpers = helpers.replaceAll(JSON.stringify(tabId), JSON.stringify(markTab)).replaceAll(JSON.stringify(windowId), JSON.stringify(markWindow));
    const capture = join(scratch, "new-tab-list.png");
    const state = await run(`${markHelpers}
      return new Promise((resolve, reject) => {
        let sampled;
        setTimeout(() => sample().then((value) => ac.shell.devSnapshotWindow(windowId, ${JSON.stringify(capture)}).then((written) => { sampled = { ...value, snapshot: written }; })).catch(reject), 1050);
        globalThis.acSwipe.pane(tabId).devSimulate(${JSON.stringify(steps)}, { ignorePreference: true }).then(() => setTimeout(() => resolve(sampled), 150), reject);
      });`);
    assert.ok(state?.snapshot && state.native?.newTabMark, `new-tab mark absent: ${JSON.stringify(state)}`);
    assert.deepEqual(state.native.items, ["ONE", "New Tab"]);
    assert.equal(state.native.selected, 1);
    assert.equal(state.lists, 0);
    const outcome = await run(`return { tab: ac.store.getState().tabs[${JSON.stringify(markTab)}], page: ac.pageState.getState().pages[${JSON.stringify(markTab)}] };`);
    writeFileSync(join(scratch, "new-tab-list.json"), JSON.stringify({ ...state, outcome }, null, 2));
    const blank = await until(`const tab = ac.store.getState().tabs[${JSON.stringify(markTab)}]; return tab?.url === "" ? { tab, page: ac.pageState.getState().pages[${JSON.stringify(markTab)}] } : null;`);
    assert.equal(blank.tab.url, "", `New Tab destination did not display a blank tab: ${JSON.stringify(blank)}`);
    return { ...state, outcome: blank };
  });
  await rep.check("little-no-haptics", async () => {
    const state = await app.snapshot({}, { timeout: 1000 });
    assert.equal(state.haptics.performed, 0);
    return state.haptics;
  });
} catch (error) {
  rep.record("run", { error });
} finally {
  await app?.quit().catch(() => {});
  server.close();
}
console.log(`${rep.results.filter((row) => row.ok).length}/${rep.results.length} passed; artifacts ${scratch}`);
process.exit(rep.results.some((row) => !row.ok) ? 1 : 0);

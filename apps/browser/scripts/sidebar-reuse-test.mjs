import assert from "node:assert/strict";
import { existsSync, mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { createServer } from "node:http";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { launch, reporter, session, sleep } from "../../../scripts/lib/instance.mjs";
import { assertSidebarPosition, sidebarPosition, sidebarSession } from "./sidebar-position-test.mjs";
import { readNativeWork, readSidebarRealization, sidebarWorkCounts, validateWindowContract } from "./perf/native-work.mjs";

const args = process.argv.slice(2);
const appArg = args.find((arg) => !arg.startsWith("--"));
if (!appArg || args.includes("--help")) {
  console.error("usage: node sidebar-reuse-test.mjs <Debug Solara.app> [--out=<fresh directory>] [--port=<port>] [--keep-data]\n\nSidebar visibility, reusable cells, 200/2000 fixed viewport, rename/drag recycling, profile/rail/group state and offscreen selection/accessibility. SOLARA_TEST_SIDEBAR_POSITION selects left or right. SOLARA_NATIVE_WINDOW_LAYOUT=0 checks the fallback layout. TMPDIR controls scratch storage.");
  process.exit(appArg ? 0 : 2);
}
process.env.AC_UITEST_WAIT ??= "90";
assert.ok(Number(process.env.AC_UITEST_WAIT) > 0 && Number(process.env.AC_UITEST_WAIT) <= 480, "UI gate wait must be bounded below ten minutes");
process.env.SOLARA_NATIVE_WINDOW_LAYOUT ??= "1";
assert.ok(["0", "1"].includes(process.env.SOLARA_NATIVE_WINDOW_LAYOUT), "SOLARA_NATIVE_WINDOW_LAYOUT must be 0 or 1");
const nativeLayout = process.env.SOLARA_NATIVE_WINDOW_LAYOUT === "1";
const outArg = args.find((arg) => arg.startsWith("--out="))?.slice(6);
const scratch = outArg ? resolve(outArg) : mkdtempSync(join(tmpdir(), `ac-sidebar-reuse-${sidebarPosition}-`));
mkdirSync(scratch, { recursive: true });
const keep = args.includes("--keep-data");
if (keep) process.env.AC_KEEP_DATA = "1";
const rep = reporter(join(scratch, "sidebar-reuse-test.log"), { name: "sidebar-reuse-test" });
const report = { sidebarPosition, viewport: [1280, 800], nativeLayout, fixtures: [] };
const save = () => writeFileSync(join(scratch, "sidebar-reuse-results.json"), JSON.stringify(report, null, 2));
const server = createServer((request, response) => {
  const id = request.url.slice(1);
  response.writeHead(200, { "content-type": "text/html" });
  response.end(`<!doctype html><title>Fixture ${id}</title><body>${id}</body>`);
});
await new Promise((done) => server.listen(0, "127.0.0.1", done));
const origin = `http://127.0.0.1:${server.address().port}`;
const fixture = (count) => session(sidebarSession({
  profiles: ["Personal", "Work"],
  windows: [{ id: "w1", frame: [80, 80, 1280, 800], activeTabIds: { default: "t0", work: "work0" } }],
  tabs: Array.from({ length: count }, (_, index) => {
    const work = index >= count - 20;
    const id = work ? `work${index - count + 20}` : `t${index}`;
    return { id, profileId: work ? "work" : "default", url: `${origin}/${id}`, title: `Fixture ${id}`, customTitle: `Fixture ${id}` };
  }),
  groups: [{ id: "g1", name: "Fixture group", windowId: "w1", profileId: "default", color: "blue", collapsed: false, pinned: false, tabIds: ["t3", "t4", "t5"], createdAt: 1 }],
  settings: { sidebarPosition, addressBar: "sidebar", tabLayout: "sidebar", newTabPosition: "top", newTabButtonPosition: "top", warnBeforeClosingLastTab: false, warnBeforeClosingWindow: false },
}));

let app;
try {
  for (const count of [200, 2000]) {
    const data = join(scratch, `${count}-tabs`, "data");
    assert.ok(!existsSync(data), `fixture data already exists; choose a fresh --out: ${data}`);
    app = await launch(resolve(appArg), { data, session: fixture(count), onboarded: true, probe: true, files: { ".new-tabs-top-0.4.1": "1" }, port: args.find((arg) => arg.startsWith("--port="))?.slice(7), ready: { timeout: 45000, test: "return !!ac.store" } });
    const result = { tabs: count, samples: [] };
    report.fixtures.push(result);
    const run = (body, timeout = 5000) => app.eval(body, { timeout });
    const until = async (what, read, accept, ms = 8000) => {
      const deadline = Date.now() + ms;
      let last;
      while (deadline - Date.now() >= 1000) {
        assert.ok(app.alive, `${what}: owned app exited`);
        last = await read();
        if (accept(last)) return last;
        await sleep(80);
      }
      throw new Error(`${what}: deadline expired, last ${JSON.stringify(last)}`);
    };
    const capture = async (name, profileId = "default") => {
      const realization = await readSidebarRealization(app, "w1");
      const current = realization.pages.find((page) => page.profileId === profileId)?.realization;
      assert.ok(current, `${name}: native profile ${profileId} probe exists`);
      for (const page of realization.pages.filter((page) => page.profileId !== profileId)) {
        assert.equal(page.realization.bound.length, 0, `${name}: unshown ${page.profileId} retains no bound cells`);
        assert.equal(page.realization.reuse.reduce((sum, bin) => sum + bin.count, 0), 0, `${name}: unshown ${page.profileId} releases its reuse bins`);
      }
      const counters = await readNativeWork(app);
      const native = await app.snapshot({ windowId: "w1", fields: ["windows.shell", "windows.tabIds", "windows.selectedTabId"] }, { timeout: 5000 });
      const window = native.windows.find((candidate) => candidate.id === "w1");
      const contract = validateWindowContract(window?.shell?.contract);
      assert.equal(contract.nativeLayout, nativeLayout, "fixture uses the requested layout owner");
      assert.equal(contract.hostCounts.sidebar, 1, "fixture retains one sidebar host");
      const sidebarCounters = sidebarWorkCounts(counters, "w1");
      const sample = { name, realization, counters, sidebarCounters, contract, selectedTabId: window.selectedTabId };
      result.samples.push(sample);
      save();
      return { ...sample, current };
    };
    const scroll = async (y) => {
      await run(`return globalThis.expo.modules.SolaraSidebarDrag.scrollTo("w1", ${y});`);
      await sleep(350);
    };
    const bindings = (sample) => sample.current.bound.filter((row) => row.key.startsWith("t:"));
    const assertLabels = async (sample) => {
      const expected = await run(`const s = ac.store.getState(); const w = s.windows.w1; const active = w.activeTabIds[w.profileId]; return Object.fromEntries(Object.values(s.tabs).map((tab) => ["t:" + tab.id, { label: tab.customTitle || tab.title, active: tab.id === active, selected: tab.id === active || (s.selection.w1 || []).includes(tab.id) }]));`);
      for (const row of bindings(sample)) {
        assert.equal(row.label, expected[row.key]?.label, `rebound ${row.key} exposes its own title`);
        assert.equal(row.active, expected[row.key]?.active, `rebound ${row.key} exposes its own active state`);
        assert.equal(row.selected, expected[row.key]?.selected, `rebound ${row.key} exposes its own selection state`);
      }
    };
    try {
      await sleep(1500);
      await assertSidebarPosition(app, "w1");
      assert.equal(await run('return globalThis.expo.modules.SolaraApp.sidebarPosition;'), nativeLayout, "sidebar side choices require native layout");
      await rep.check(`${count}: fixed viewport realizes only exact native visible intersections`, async () => {
        await scroll(0);
        const before = await capture("initial");
        assert.ok(before.current.bound.length > 0 && before.current.bound.length < 100, "visible row demand is positive and smaller than the fixture");
        assert.ok(before.sidebarCounters.live < 100, "Patch 1 sidebar live census is bounded at the fixed viewport");
        await assertLabels(before);
        result.initial = { live: before.sidebarCounters.live, created: before.sidebarCounters.created, bound: before.current.bound.length, bounds: before.contract.bounds, sidebar: before.contract.sidebar };
      });
      await rep.check(`${count}: repeated down/up passes reuse allocation identities and reach a bounded high-water mark`, async () => {
        const seen = new Map();
        let rebound = 0;
        const cycle = async (name) => {
          for (const y of [0, 370, 740, 1110, 1480, 1110, 740, 370, 0]) {
            await scroll(y);
            const sample = await capture(`${name}-${y}`);
            await assertLabels(sample);
            for (const row of sample.current.bound) {
              const prior = seen.get(row.allocationId);
              if (prior && prior.key !== row.key) {
                assert.ok(row.token > prior.token, "new identity advances the binding token");
                rebound++;
              }
              seen.set(row.allocationId, { key: row.key, token: row.token });
            }
          }
        };
        await cycle("warm");
        assert.ok(rebound > 0, "at least one concrete allocation is rebound to a different logical identity");
        await readNativeWork(app, true);
        const allocated = new Set(seen.keys());
        await cycle("repeat");
        const work = await readNativeWork(app);
        const sidebarWork = sidebarWorkCounts(work, "w1");
        assert.equal(sidebarWork.created, 0, "a repeated identical scroll path allocates no new concrete rows");
        assert.ok(sidebarWork.reused > 0 && sidebarWork.bound > 0, "native counters record reuse and binding work");
        assert.deepEqual(new Set(seen.keys()), allocated, "second pass stays within the warmed allocation identities");
        result.scroll = { rebound, allocations: allocated.size, work };
      });
      if (count === 2000) {
        await rep.check("a dragged source leaves no offscreen cell after scroll, then cancels or drops by identity", async () => {
          const nativeDrag = () => run('return globalThis.expo.modules.SolaraSidebarDrag.startProbe("w1").then(JSON.parse);');
          const post = async (phase, x, y) => {
            await run(`const C = globalThis.expo.modules.SolaraCEF; return C.chromeWindows().then((windows) => { const window = windows.find((candidate) => candidate.hasRoot); if (!window) throw new Error("fixture Chrome window unavailable"); return C.devWindow(window.window, ${JSON.stringify(`mouse:${phase}:${Math.round(x)},${Math.round(y)}`)}); });`);
            await sleep(80);
          };
          for (const commit of [false, true]) {
            await scroll(0);
            const before = await run('return ac.store.getState().windows.w1.tabIds;');
            const row = await run('return ac.sidebarRows.measureRow("w1", "t2");');
            assert.ok(row && row.height > 0, "source has a native visible cell");
            const x = row.x + Math.min(50, row.width / 2), y = row.y + row.height / 2;
            await post("down", x, y);
            try {
              await post("dragged", x + 8, y + 5);
              await post("dragged", x + 12, y + 16);
              const started = await until("native source drag", nativeDrag, (probe) => probe?.active === true);
              assert.deepEqual(started.marks.sources, ["t:t2"], "native controller owns the source identity");
              await scroll(1480);
              const after = await capture(`source-drag-${commit ? "drop" : "cancel"}`);
              assert.ok(!after.current.bound.some((binding) => binding.key === "t:t2"), "live drag source cell is recycled offscreen");
              const probe = await nativeDrag();
              assert.equal(probe.active, true, "scroll preserves the native drag session");
              if (commit) {
                const target = probe.items.find((item) => item.kind === "row" && item.tabIds.length === 1 && item.tabIds[0] !== "t2" && item.y > probe.viewport.y + 40 && item.y + item.h < probe.viewport.y + probe.viewport.h - 40);
                assert.ok(target, "a visible logical target exists after scrolling");
                await post("dragged", target.x + Math.min(50, target.w / 2), target.y + target.h - 3);
                await post("up", target.x + Math.min(50, target.w / 2), target.y + target.h - 3);
                const moved = await until("native source reorder", () => app.snapshot({ windowId: "w1", fields: ["windows.tabIds"] }, { timeout: 1000 }), (state) => {
                  const order = state.windows.find((window) => window.id === "w1")?.tabIds;
                  return order && order.indexOf("t2") !== before.indexOf("t2");
                });
                const order = moved.windows.find((window) => window.id === "w1").tabIds;
                assert.deepEqual(new Set(order), new Set(before), "drop retains every tab identity");
                assert.equal(Math.abs(order.indexOf("t2") - order.indexOf(target.tabIds[0])), 1, "recycled source drops beside the actual visible target");
              } else {
                await run('return globalThis.expo.modules.SolaraSidebarDrag.escape();');
                await post("up", x, y);
                await until("native drag cancellation", nativeDrag, (probe) => probe?.active === false);
                assert.deepEqual(await run('return ac.store.getState().windows.w1.tabIds;'), before, "cancel retains logical tab order");
              }
            } finally {
              await run('return globalThis.expo.modules.SolaraSidebarDrag.escape();');
              await post("up", x, y);
            }
            await sleep(400);
            await capture(`source-drag-${commit ? "dropped" : "cancelled"}`);
          }
        });
        await rep.check("an edited row commits before scroll recycles its field", async () => {
          await scroll(0);
          assert.equal(await run('return expo.modules.SolaraHosted.beginRename("w1", "tab", "t1");'), true, "native rename accepted");
          const editor = () => run('const editing = ac.sidebarRows.useSidebarUi.getState().renaming; return editing?.windowId === "w1" ? editing.id : null;');
          await until("rename editor opens", editor, (id) => id === "t1");
          await sleep(250);
          await run('return ac.shell.devTypeKeys("w1", "Recycled rename", 10);');
          await scroll(1480);
          const nativeTitle = () => run('const module = globalThis.expo.modules.SolaraStoreAdapter; if (!module || typeof module.snapshot !== "function" || !(module.status().active && module.status().frozen === false)) throw new Error("native workspace snapshot unavailable"); const snapshot = JSON.parse(module.snapshot()); const tab = snapshot.data.tabs.t1; if (!tab || !Number.isSafeInteger(snapshot.rev)) throw new Error("native renamed tab unavailable"); return { rev: snapshot.rev, id: tab.id, customTitle: tab.customTitle ?? null };', 1000);
          const state = await until("rename commit", nativeTitle, (value) => value.id === "t1" && value.customTitle === "Recycled rename");
          assert.equal(state.customTitle, "Recycled rename");
          result.rename = state;
          save();
          const after = await capture("rename-offscreen");
          assert.ok(!after.current.bound.some((row) => row.key === "t:t1"), "edited cell is released offscreen");
          await until("field editor identity closes", editor, (id) => id === null);
          await assertLabels(after);
        });
        await rep.check("native offscreen selection and virtual accessibility reveal materialize the requested identity", async () => {
          const id = "t1500";
          await scroll(0);
          assert.ok(!(await capture("before-selection")).current.bound.some((row) => row.key === `t:${id}`));
          await run(`ac.store.getState().activate(${JSON.stringify(id)}); return true;`);
          await until("offscreen active selection", () => app.snapshot({ windowId: "w1", fields: ["windows.selectedTabId"] }, { timeout: 1000 }), (state) => state.windows.find((window) => window.id === "w1")?.selectedTabId === id);
          await sleep(400);
          const selected = await capture("selected-offscreen");
          assert.ok(selected.current.bound.some((row) => row.key === `t:${id}`), "selection reveals and binds the offscreen row");
          await assertLabels(selected);
          const edge = bindings(selected).sort((a, b) => a.frame[1] - b.frame[1]).at(-1);
          assert.ok(edge, "the selected viewport exposes a last logical tab");
          const next = await run(`const s = ac.store.getState(); const ids = s.windows.w1.tabIds.filter((id) => s.tabs[id].profileId === "default"); return ids[ids.indexOf(${JSON.stringify(edge.key.slice(2))}) + 1];`);
          assert.ok(next && !selected.current.bound.some((row) => row.key === `t:${next}`), "keyboard target begins outside the realized viewport");
          await run(`ac.store.getState().activate(${JSON.stringify(edge.key.slice(2))}); return true;`);
          await until("keyboard traversal start", () => app.snapshot({ windowId: "w1", fields: ["windows.selectedTabId"] }, { timeout: 1000 }), (state) => state.windows.find((window) => window.id === "w1")?.selectedTabId === edge.key.slice(2));
          const key = await run('return ac.shell.devKeyEquivalent("w1", { key: "}", keyCode: 30, modifiers: ["command", "shift"], focus: "window", wait: 50 });');
          assert.ok(!key?.error, `native Next Tab shortcut routed: ${JSON.stringify(key)}`);
          await until("keyboard traversal crosses viewport edge", () => app.snapshot({ windowId: "w1", fields: ["windows.selectedTabId"] }, { timeout: 1000 }), (state) => state.windows.find((window) => window.id === "w1")?.selectedTabId === next);
          await sleep(350);
          const keyboard = await capture("keyboard-offscreen");
          assert.ok(keyboard.current.bound.some((row) => row.key === `t:${next}`), "real keyboard traversal reveals and binds the next logical tab");
          await assertLabels(keyboard);
          const target = "t1700";
          const ax = await run(`const module = globalThis.expo.modules.SolaraHosted; if (typeof module.devSidebarAccessibility !== "function") throw new Error("virtual sidebar accessibility action unavailable"); return module.devSidebarAccessibility("w1", "t:${target}", "press").then(JSON.parse);`);
          assert.equal(ax.performed, true, "actual virtual AX element accepts press");
          await until("virtual AX selection", () => app.snapshot({ windowId: "w1", fields: ["windows.selectedTabId"] }, { timeout: 1000 }), (state) => state.windows.find((window) => window.id === "w1")?.selectedTabId === target);
          await sleep(350);
          assert.ok((await capture("accessibility-offscreen")).current.bound.some((row) => row.key === `t:${target}`), "virtual AX action reveals its offscreen row");
        });
        await rep.check("rail, collapsed group and profile-away states keep exact visible row bounds", async () => {
          await run('ac.store.getState().activate("t0"); ac.store.getState().updateGroup("g1", { collapsed: true }); return true;');
          await scroll(0);
          const collapsed = await capture("group-collapsed");
          for (const id of ["t3", "t4", "t5"]) assert.ok(!collapsed.current.logical.some((item) => item.key === `t:${id}`), "collapsed members have no logical visible row");
          await run('ac.runCommand({ command: "toggleSidebarIconsOnly", arg: null, windowId: "w1" }); return true;');
          await sleep(500);
          const rail = await capture("rail");
          assert.ok(rail.current.bound.length > 0 && rail.current.bound.length < 100, "rail realizes a viewport-sized set");
          await run('ac.store.getState().switchProfile("w1", "work"); return true;');
          await sleep(600);
          await capture("work-profile", "work");
          await run('ac.store.getState().switchProfile("w1", "default"); ac.runCommand({ command: "toggleSidebarIconsOnly", arg: null, windowId: "w1" }); ac.store.getState().updateGroup("g1", { collapsed: false }); return true;');
          await sleep(600);
          await capture("profile-return");
        });
      }
    } finally {
      await app.quit();
      app = null;
      if (!keep && !rep.failed.length) rmSync(data, { recursive: true, force: true });
    }
  }
  await rep.check("200 and 2000 tabs have identical live row demand and native viewport", async () => {
    const [small, big] = report.fixtures.map((result) => result.initial);
    assert.ok(small && big, "both fixed viewport fixtures produced native evidence");
    assert.deepEqual(big.bounds, small.bounds);
    assert.deepEqual(big.sidebar, small.sidebar);
    assert.equal(big.live, small.live, "Patch 1 native live rows do not scale with tab count");
    assert.equal(big.bound, small.bound, "exact visible binding count does not scale with tab count");
  });
} finally {
  await app?.quit();
  server.close();
  report.checks = rep.results;
  save();
}
process.exit(rep.summary() ? 0 : 1);

import assert from "node:assert/strict";
import { mkdtempSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { launch, reporter, sleep } from "../../../scripts/lib/instance.mjs";

const appPath = process.argv[2];
if (!appPath) throw new Error("usage: node launch-scheduling-test.mjs <Debug Solara.app> [scratch]");
const scratch = process.argv[3] ? resolve(process.argv[3]) : mkdtempSync(join(tmpdir(), "solara-launch-work-"));
const rep = reporter(join(scratch, "launch-scheduling.log"), { name: "launch-scheduling" });
let app;
let firstWindowId;
const read = async (command = "snapshot", options = {}) => app.eval(`return globalThis.expo.modules.SolaraWindowShell.devLaunchWork(${JSON.stringify(command)}, ${JSON.stringify(options)}).then(value => typeof value === "string" ? JSON.parse(value) : value);`);
const until = async (description, test, milliseconds = 8000) => {
  let last;
  for (const end = Date.now() + milliseconds; Date.now() < end;) {
    last = await read();
    if (test(last)) return last;
    await sleep(30);
  }
  throw new Error(`${description}: ${JSON.stringify(last)}`);
};
const job = (snapshot, id) => snapshot.jobs?.find(entry => entry.id === id);

try {
  app = await launch(resolve(appPath), { data: join(scratch, "data"), fresh: true, onboarded: true });
  firstWindowId = await app.eval("return ac.store.getState().windowOrder[0];");
  await rep.check("native readiness reaches a chrome commit", async () => {
    const state = await until("native chrome commit", value => Number.isFinite(value.chromeCommittedAt));
    assert.ok(state.windows.some(window => window.storeReady && window.ownerReady && window.slotsReady && window.guestReady));
    return state;
  });
  await rep.check("input pauses bounded optional chunks", async () => {
    const result = await app.eval(`const native = globalThis.expo.modules.SolaraWindowShell;
      return native.devLaunchWork("input", { holdMs: 1200 }).then(() =>
        native.devLaunchWork("queue", { id: "input-held", chunks: 20, milliseconds: 2 }));`);
    assert.ok(result);
    const before = await read();
    await sleep(200);
    const held = await read();
    assert.equal(job(held, "input-held")?.runs ?? 0, job(before, "input-held")?.runs ?? 0);
    const settled = await until("bounded optional chunks finish", state => job(state, "input-held")?.runs === 20);
    assert.ok(settled.idleOpportunities >= 20);
    return { held, settled };
  });
  await rep.check("demand promotes an optional job at the next idle opportunity", async () => {
    await read("input", { holdMs: 600 });
    await read("queue", { id: "background", chunks: 100 });
    await read("queue", { id: "demanded", chunks: 1 });
    await read("promote", { id: "demanded" });
    const promoted = await until("promoted work runs", state => job(state, "demanded")?.runs === 1);
    assert.equal(job(promoted, "demanded")?.runs, 1);
    assert.ok((job(promoted, "background")?.runs ?? 0) < 100);
    await read("cancel", { id: "background" });
    return promoted;
  });
  await rep.check("delayed required React guest cannot become usable chrome", async () => {
    const id = await app.eval("globalThis.acDevMountDelayMs = 1500; return ac.store.getState().createWindow();");
    assert.ok(id);
    const early = await until("delayed guest registration", state => state.windows.some(entry => entry.windowId === id));
    const window = early.windows.find(entry => entry.windowId === id);
    assert.ok(window);
    assert.equal(window.guestReady, false);
    assert.ok(!Number.isFinite(window.chromeCommittedAt));
    const ready = await until("delayed guest chrome commit", state => Number.isFinite(state.windows.find(entry => entry.windowId === id)?.chromeCommittedAt));
    await app.eval("globalThis.acDevMountDelayMs = 0; return true;");
    return { id, early, ready };
  });
  await rep.check("closing and reopening the first window fences its pending chunks", async () => {
    const id = firstWindowId;
    assert.ok(id);
    assert.ok(await app.eval(`const state = ac.store.getState();
      state.newTab(${JSON.stringify(id)}, { url: "data:text/html,<title>Launch fixture</title>" });
      const current = ac.store.getState();
      return current.windows[${JSON.stringify(id)}].tabIds.some(id => !!current.tabs[id]?.url);`));
    await read("input", { holdMs: 1200 });
    await read("queue", { id: "closed-generation", chunks: 50, windowId: id });
    await app.eval(`ac.store.getState().closeWindow(${JSON.stringify(id)}); return true;`);
    await sleep(1400);
    const state = await read();
    assert.ok(!state.windows.some(entry => entry.windowId === id));
    assert.equal(job(state, "closed-generation")?.runs ?? 0, 0);
    assert.equal(job(state, "closed-generation")?.pending ?? false, false);
    assert.ok(state.cancelled > 0);
    const reopenedId = await app.eval("const state = ac.store.getState(); const prior = new Set(Object.keys(state.windows)); state.reopenClosedWindow(); return Object.keys(ac.store.getState().windows).find(id => !prior.has(id));");
    assert.ok(reopenedId);
    await until("reopened window chrome", state => Number.isFinite(state.windows.find(entry => entry.windowId === reopenedId)?.chromeCommittedAt));
    await read("queue", { id: "reopened-generation", chunks: 1, windowId: reopenedId });
    const reopened = await until("new generation work runs", state => job(state, "reopened-generation")?.runs === 1);
    assert.equal(job(reopened, "closed-generation")?.runs ?? 0, 0);
    return { closed: state, reopened };
  });
  writeFileSync(join(scratch, "launch-work.json"), JSON.stringify(await read(), null, 2));
} finally {
  if (app) await app.quit();
}
process.exitCode = rep.summary() ? 0 : 1;

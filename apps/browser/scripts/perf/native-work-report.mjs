import assert from "node:assert/strict";
import { existsSync, mkdirSync, writeFileSync } from "node:fs";
import { createServer } from "node:http";
import { join, resolve } from "node:path";
import { launch } from "../../../../scripts/lib/instance.mjs";
import { buildSeed } from "./seed.mjs";
import { NATIVE_WORK_REVISION, nativeWorkCounts, readNativeWork, validateNativeWork, validateWindowContract } from "./native-work.mjs";

const total = (counter) => Object.values(counter ?? {}).reduce((sum, value) => sum + value, 0);
const nativeSignature = (sample) => JSON.stringify({
  counts: nativeWorkCounts(sample),
  groups: sample.groups.map((group) => [group.windowId, group.profileId, group.kind, group.created, group.bound, group.reused, group.live]).sort(),
  hosts: sample.hosts.map((host) => [host.windowId, host.kind, host.count]).sort(),
});
async function settleFixture(app, path) {
  const started = Date.now();
  const samples = [];
  const read = async (windowed = false) => {
    const sample = await app.eval(`async function sampleFixture() {
      if (${windowed}) {
        acPerf.reset();
        await new Promise((done) => setTimeout(done, 3000));
      }
      const state = ac.store.getState();
      const shownProfiles = [...new Set(Object.values(state.windows).map((window) => window.profileId))].filter((id) => !id.startsWith("incognito:"));
      const nativeWork = JSON.parse(await globalThis.expo.modules.SolaraWindowShell.nativeWork(false));
      return { shownProfiles, historyReady: state.historyReady, profileOrder: state.profileOrder, nativeWork, stats: acPerf.read() };
    } return sampleFixture();`, { timeout: 5000 });
    validateNativeWork(sample.nativeWork);
    samples.push({ elapsedMs: Date.now() - started, ...sample });
    writeFileSync(path, JSON.stringify({ settlement: "shownProfilesAndNativeQuiet", quietMs: 3000, timeoutMs: 45000, samples }, null, 2));
    return sample;
  };
  let before = await read();
  while (Date.now() - started < 45000) {
    if (!app.alive) throw new Error("fixture exited before settling");
    const after = await read(true);
    const ready = after.shownProfiles.every((id) => after.historyReady[id]);
    const quiet = !after.stats.commits && !total(after.stats.storeUpdates) && !total(after.stats.writes)
      && !after.nativeWork.activeAnimationLinks && !after.nativeWork.pendingDeferredJobs;
    if (ready && quiet && nativeSignature(before.nativeWork) === nativeSignature(after.nativeWork)) return;
    before = after;
  }
  throw new Error(`fixture launch did not settle; diagnostics: ${path}`);
}

const args = process.argv.slice(2);
const appPath = args.find((arg) => !arg.startsWith("--"));
const out = args.find((arg) => arg.startsWith("--out="))?.slice(6);
if (!appPath || !out) throw new Error("usage: node native-work-report.mjs <Debug app> --out=<fresh directory>");
mkdirSync(out, { recursive: true });
const server = createServer((_, response) => { response.writeHead(200, { "content-type": "text/html" }); response.end("<!doctype html><title>Layout contract fixture</title><body>Layout contract fixture</body>"); });
await new Promise((done) => server.listen(0, "127.0.0.1", done));
const origin = `http://127.0.0.1:${server.address().port}`;
const baseFiles = buildSeed(origin);
const report = { nativeWorkRevision: NATIVE_WORK_REVISION, viewport: [1440, 900], launchBoundary: "openToSettled", settlement: "shownProfilesAndNativeQuiet", results: [] };
try {
  for (const count of [1, 200, 2000]) {
    const files = structuredClone(baseFiles);
    const fixture = files["session.json"];
    const window = fixture.windows[0];
    if (count === 1) {
      const keep = window.activeTabIds.default;
      fixture.tabs = fixture.tabs.filter((tab) => tab.id === keep);
      fixture.groups = [];
      fixture.profiles = { default: fixture.profiles.default };
      fixture.profileOrder = ["default"];
      window.tabIds = [keep];
      window.activeTabIds = { default: keep };
    } else {
      const template = fixture.tabs.find((tab) => tab.profileId === "default" && !tab.pinned);
      for (let at = 200; at < count; at++) {
        const tab = { ...template, id: `extra-${at}`, url: `${origin}/extra-${at}`, title: `Extra tab ${at}`, createdAt: template.createdAt + at };
        fixture.tabs.push(tab);
        window.tabIds.push(tab.id);
      }
    }
    assert.equal(fixture.tabs.length, count);
    const data = join(resolve(out), `${count}-tabs`, "data");
    if (existsSync(data)) throw new Error(`fixture data already exists; choose a fresh --out directory: ${data}`);
    const app = await launch(resolve(appPath), { data, files, probe: true });
    try {
      await settleFixture(app, join(out, `${count}-settlement.json`));
      const startup = await readNativeWork(app);
      const snapshot = await app.snapshot({ windowId: "w-bench", fields: ["windows.shell", "windows.tabIds"] });
      assert.ok(Number.isFinite(app.launchedAt), "instance supplies the launch boundary after the UI gate");
      const launchElapsedMs = Date.now() - app.launchedAt;
      const nativeWindow = snapshot.windows.find((candidate) => candidate.id === "w-bench");
      assert.equal(nativeWindow.tabIds.length, count, "native window contains the fixture tab count");
      const contract = validateWindowContract(nativeWindow.shell.contract);
      assert.equal(contract.hostCounts.sidebar, 1, "one native sidebar host at each tab count");
      assert.ok(contract.pageIdentities.some((page) => page.tabId === window.activeTabIds.default), "selected pooled page identity is present");
      if (report.results.length) {
        const previous = report.results.at(-1).before.windows.find((candidate) => candidate.id === "w-bench").shell.contract;
        assert.deepEqual(contract.bounds, previous.bounds, "tab-count fixtures keep identical native viewport bounds");
        assert.deepEqual(contract.sidebar, previous.sidebar, "tab-count fixtures keep identical sidebar bounds");
      }
      await readNativeWork(app, true);
      const scrolling = performance.now();
      await app.eval(`async function scrollFixture() {
        const drag = globalThis.expo.modules.SolaraSidebarDrag;
        if (!drag || typeof drag.scrollTo !== "function") throw new Error("native sidebar scroll unavailable");
        for (const direction of [1, -1]) {
          for (let step = 0; step <= 60; step++) {
            await drag.scrollTo("w-bench", direction === 1 ? step * 40 : 2400 - step * 40);
            await new Promise((done) => setTimeout(done, 16));
          }
        }
        await new Promise((done) => setTimeout(done, 300));
        return true;
      } return scrollFixture();`, { timeout: 30000 });
      const scrollElapsedMs = performance.now() - scrolling;
      const scroll = await readNativeWork(app);
      const after = await app.snapshot({ windowId: "w-bench", fields: ["windows.shell", "windows.tabIds"] });
      const beforeShell = snapshot.windows.find((candidate) => candidate.id === "w-bench").shell;
      validateWindowContract(beforeShell.contract);
      const afterWindow = after.windows.find((candidate) => candidate.id === "w-bench");
      assert.equal(afterWindow.tabIds.length, count, "native tab count survives scrolling");
      assert.deepEqual(afterWindow.tabIds, nativeWindow.tabIds, "scrolling preserves native tab IDs and order");
      const afterShell = afterWindow.shell;
      validateWindowContract(afterShell.contract);
      assert.deepEqual(afterShell.contract, beforeShell.contract, "scroll preserves shell geometry, hosts and pooled page identities");
      assert.ok(startup.rows.live >= count, `eager baseline retains at least ${count} row views (${startup.rows.live})`);
      assert.equal(scroll.rows.created, 0, "scroll reuses retained eager rows");
      report.results.push({ seed: count === 1 ? "small" : count === 200 ? "big" : "fixedViewport2000", tabs: count, launchElapsedMs, scrollElapsedMs, startup, scroll, before: snapshot, after });
      writeFileSync(join(out, "report.json"), JSON.stringify(report, null, 2));
      console.log(`${count} tabs: ${JSON.stringify({ launchElapsedMs, scrollElapsedMs, startup, scroll })}`);
    } finally { await app.quit(); }
  }
} finally { server.close(); }

#!/usr/bin/env node
import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { existsSync, mkdirSync, mkdtempSync, realpathSync, writeFileSync } from "node:fs";
import { createServer } from "node:http";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { parseArgs } from "node:util";

const help = `usage: METRO_PORT=<port> node lazy-profiles-test.mjs <Debug Solara.app> [--runs 2] [--settle-ms 8000] [--usage-bin <acperf>] [--out <file>]

Profiles load when opened, end to end, in hidden scratch instances. Eight profiles (Default and seven more), each
with a pinned tab, a regular tab, a bookmark and the same unpacked MV3 extension, are made once in a fixture launch
with every profile loaded. Each run then starts from a copy of that fixture.

  measure  --runs pairs of launches, lazy then eager (settings.loadAllProfilesAtLaunch), interleaved: the engine
           profiles loaded (SolaraCEF.loadedProfiles, which loads nothing), the process tree, summed RSS and, with
           --usage-bin (an acperf binary from scripts/perf/acperf.swift), summed phys_footprint, after --settle-ms.
  sync     sync turned on with every profile loaded, then --runs pairs of launches with sync on, lazy then eager:
           launch memory, and that a sync cycle loads nothing; on the last lazy launch a cold profile is switched to
           and must sync once it loads
  checks   one lazy launch: the native bookmark projection, History and Bookmarks pages and favicons with an
           unloaded profile start nothing; the first switch to an unloaded profile commits the sidebar before its
           engine profile loads and its page arrives (timed); a return switch starts nothing; a pinned tab of an
           unloaded profile and a link opened into one load just that profile; a profile's history, bookmarks and
           favicon arrive once it opens; a bookmark added to an unloaded profile is accepted (whether it loads the
           profile is recorded); a private window of an unloaded profile works and closes; deleting an unused,
           never-loaded profile removes its data without loading it; turning the setting on loads the rest; quit
           is graceful; a relaunch on the same data loads only Default and the window's profile, with no crash.
  webkit   a WebKit-only launch on Default loads only Default in Chromium; a WebKit tab of an unloaded profile has
           no page until its window shows it; after the switch, the WebKit blocker (its state read from Default,
           which always loads) blocks an ad script while the page's own script loads (whether the switch loaded the
           profile in Chromium is recorded)

Writes JSON evidence to --out (default <scratch>/lazy-profiles.json). Scratch data is kept; the last line names it.
`;

const { values, positionals } = parseArgs({ allowPositionals: true, options: {
  help: { type: "boolean" }, runs: { type: "string", default: "2" }, "settle-ms": { type: "string", default: "8000" },
  "usage-bin": { type: "string" }, out: { type: "string" },
} });
if (values.help || positionals.length !== 1) {
  process.stdout.write(help);
  process.exit(values.help ? 0 : 2);
}

const appPath = realpathSync(resolve(positionals[0]));
assert.ok(!appPath.startsWith("/Applications/") && !appPath.includes("/build-vista/"), "use an isolated build, never an installed or preview app");
const settle = Number(values["settle-ms"]);
const runs = Number(values.runs);
assert.ok(Number.isInteger(settle) && settle >= 1000 && settle <= 30000, "--settle-ms must be 1000..30000");
assert.ok(Number.isInteger(runs) && runs >= 1 && runs <= 5, "--runs must be 1..5");
const usageBin = values["usage-bin"] ? resolve(values["usage-bin"]) : null;
const { launch, session, sleep, crashReportsForInstance } = await import("../../../scripts/lib/instance.mjs");

const root = mkdtempSync(join(tmpdir(), "ac-lazy-profiles-"));
const out = resolve(values.out ?? join(root, "lazy-profiles.json"));
const report = { appPath, scratch: root, startedAt: new Date().toISOString(), settleMs: settle, fixture: null, measure: [], checks: [], summary: null, status: "running" };
const save = () => writeFileSync(out, JSON.stringify(report, null, 2) + "\n");

const profileIds = ["default", ...Array.from({ length: 7 }, (_, n) => `p-lazyprofiles-${n + 1}`)];
const engineOf = (id) => (id === "default" ? "" : id);
const sorted = (names) => [...new Set(names)].sort();
const same = (a, b) => JSON.stringify(sorted(a)) === JSON.stringify(sorted(b));

const scriptHits = [];
const server = createServer((req, res) => {
  const path = req.url.split("?")[0];
  if (path === "/xpopup/xpopup.js" || path === "/allowed.js") {
    scriptHits.push(req.url);
    res.writeHead(200, { "content-type": "text/javascript", "cache-control": "no-store" });
    return res.end("");
  }
  if (path === "/favicon.ico") {
    res.writeHead(200, { "content-type": "image/svg+xml" });
    return res.end(`<svg xmlns="http://www.w3.org/2000/svg" width="16" height="16"><rect width="16" height="16" fill="#3a7"/></svg>`);
  }
  res.writeHead(200, { "content-type": "text/html" });
  res.end(`<!doctype html><title>${path}</title><link rel="icon" href="/favicon.ico"><a id="child" target="_blank" href="/child${path.replace(/\//g, "-")}">child</a><p>lazy profile fixture</p>`);
});
await new Promise((done) => server.listen(0, "127.0.0.1", done));
const origin = `http://127.0.0.1:${server.address().port}`;

const extension = join(root, "extension");
mkdirSync(extension);
writeFileSync(join(extension, "manifest.json"), JSON.stringify({
  manifest_version: 3, name: "Lazy profile fixture", version: "1.0", permissions: ["storage"],
  background: { service_worker: "worker.js" },
}));
writeFileSync(join(extension, "worker.js"), [
  "chrome.runtime.onStartup.addListener(() => chrome.storage.local.set({ startedAt: Date.now() }));",
  "chrome.runtime.onInstalled.addListener(() => chrome.storage.local.set({ installedAt: Date.now() }));",
  "setInterval(() => chrome.storage.local.set({ beat: Date.now() }), 20000);",
].join("\n"));

const fixtureSession = (eager) => session({
  profiles: profileIds.map((id, index) => ({ id, name: `Profile ${index + 1}` })),
  windows: [{ id: "w1", profileId: "default", activeTabIds: Object.fromEntries(profileIds.map((id, index) => [id, `tab-${index}`])) }],
  tabs: profileIds.flatMap((profileId, index) => [
    { id: `pin-${index}`, profileId, pinned: true, url: `${origin}/pin-${index}`, title: `Pin ${index + 1}` },
    { id: `tab-${index}`, profileId, url: `${origin}/tab-${index}`, title: `Tab ${index + 1}` },
  ]),
  settings: { loadAllProfilesAtLaunch: eager, warnBeforeClosingLastTab: false, warnBeforeClosingWindow: false, cliControl: false },
});

const env = { SOLARA_NATIVE_SCOPE: "everything", SOLARA_NATIVE_SHELL: "1", SOLARA_SHELL_PANES: "1", SOLARA_NATIVE_PAGES_POOL: "1", SOLARA_TAB_POOL: "1" };
let app = null;

async function start(data, eager, { fresh = true, folder = null } = {}) {
  const startedAt = Date.now();
  app = await launch(appPath, { data, ...(fresh ? { session: fixtureSession(eager) } : {}), onboarded: true, probe: true, keepData: true, startTimeout: 60000,
    env: folder ? { ...env, SOLARA_SYNC_DEFAULT_FOLDER: folder } : env,
    ready: { timeout: 180000, test: "return !!ac.store && !!ac.store.getState().windows.w1;" } });
  return { pid: app.pid, readyMs: Date.now() - startedAt };
}

const evaluate = (body, timeout = 10000) => app.eval(body, { timeout });
const loadedNow = async () => sorted(await evaluate(`return globalThis.expo.modules.SolaraCEF.loadedProfiles();`));
async function until(what, accept, timeout = 20000, interval = 50) {
  const deadline = Date.now() + timeout;
  let last;
  while (Date.now() < deadline) {
    assert.ok(app.alive, `${what}: the app died`);
    last = await accept();
    if (last) return last;
    await sleep(interval);
  }
  throw new Error(`${what}: deadline, last ${JSON.stringify(last)}`);
}

function processTree(rootPid) {
  const rows = execFileSync("ps", ["-axo", "pid=,ppid=,rss=,command="], { encoding: "utf8", timeout: 5000, maxBuffer: 1 << 26 })
    .split("\n").map((line) => /^\s*(\d+)\s+(\d+)\s+(\d+)\s+(.*)$/.exec(line))
    .filter(Boolean).map((m) => ({ pid: Number(m[1]), ppid: Number(m[2]), rssBytes: Number(m[3]) * 1024, command: m[4] }));
  const owned = new Set([rootPid]);
  for (let previous = -1; previous !== owned.size;) {
    previous = owned.size;
    for (const row of rows) if (owned.has(row.ppid)) owned.add(row.pid);
  }
  const processes = rows.filter((row) => owned.has(row.pid));
  let footprint = null;
  if (usageBin) {
    const usage = execFileSync(usageBin, ["rusage", ...processes.map((row) => String(row.pid))], { encoding: "utf8", timeout: 5000 })
      .trim().split("\n").filter(Boolean).map((line) => JSON.parse(line));
    footprint = { complete: processes.every((row) => usage.some((u) => u.pid === row.pid)), bytes: usage.reduce((sum, u) => sum + u.footprint, 0) };
  }
  const kind = (command) => /--type=([a-z-]+)/.exec(command)?.[1] ?? "browser";
  const kinds = {};
  for (const row of processes) {
    const k = /--extension-process/.test(row.command) ? "extension" : kind(row.command);
    kinds[k] = (kinds[k] ?? 0) + 1;
  }
  return { count: processes.length, kinds, rssBytes: processes.reduce((sum, row) => sum + row.rssBytes, 0), footprintBytes: footprint?.bytes ?? null, footprintComplete: footprint?.complete ?? null };
}

const step = async (name, body) => {
  const started = Date.now();
  const entry = { name, ok: false };
  report.checks.push(entry);
  try {
    Object.assign(entry, (await body()) ?? {});
    entry.ok = true;
  } catch (error) {
    entry.error = error.stack ?? String(error);
  }
  entry.ms = Date.now() - started;
  save();
  process.stdout.write(`${entry.ok ? "ok  " : "FAIL"} ${name}${entry.ok ? "" : `: ${String(entry.error).split("\n")[0]}`}\n`);
  return entry.ok;
};

const chromiumDir = (data, id) => join(data, "Chromium", id === "default" ? "Default" : `Profile ${id}`);

async function fixture() {
  const data = join(root, "fixture");
  const started = await start(data, true);
  await until("every profile loads", async () => same(await loadedNow(), profileIds.map(engineOf)), 60000, 250);
  const installed = {};
  for (const id of profileIds) {
    const result = await evaluate(`return globalThis.expo.modules.SolaraExtensions.install(${JSON.stringify(extension)}, ${JSON.stringify(engineOf(id))});`, 30000);
    assert.ok(result && typeof result.id === "string", `extension install into ${id}: ${JSON.stringify(result)}`);
    installed[id] = result.id;
  }
  for (const id of profileIds) {
    await evaluate(`return ac.bookmarks.addBookmark({ profileId: ${JSON.stringify(id)}, title: ${JSON.stringify(`Mark ${id}`)}, url: ${JSON.stringify(`${origin}/mark-${id}`)} });`, 20000);
  }
  for (const [index, id] of profileIds.entries()) {
    await evaluate(`ac.store.getState().switchProfile("w1", ${JSON.stringify(id)}); return true;`);
    await until(`${id} page title`, () => evaluate(`return ac.store.getState().tabs["tab-${index}"]?.title === "/tab-${index}";`), 30000, 200);
  }
  await evaluate(`ac.store.getState().switchProfile("w1", "default"); return true;`);
  await sleep(3000);
  const listed = {};
  for (const id of profileIds) {
    const result = await evaluate(`return globalThis.expo.modules.SolaraExtensions.list(${JSON.stringify(engineOf(id))});`, 20000);
    listed[id] = (result?.extensions ?? []).some((e) => e.id === installed[id]);
  }
  assert.ok(Object.values(listed).every(Boolean), `extension listed in every profile: ${JSON.stringify(listed)}`);
  await app.quit({ timeout: 30000, graceful: true });
  assert.ok(!app.alive, "fixture instance quit");
  app = null;
  report.fixture = { data, readyMs: started.readyMs, extensionIds: installed, listed };
  save();
  return data;
}

const copyFixture = (from, to) => execFileSync("cp", ["-Rc", from, to], { timeout: 120000 });

async function measure(from) {
  for (let run = 0; run < runs; run++) {
    for (const eager of [false, true]) {
      const mode = eager ? "eager" : "lazy";
      const data = join(root, `${mode}-${run + 1}`);
      copyFixture(from, data);
      const started = await start(data, eager);
      const expected = eager ? profileIds.map(engineOf) : [""];
      const loadedAt = Date.now();
      await until(`${mode} launch loads`, async () => same(await loadedNow(), expected), 60000, 250);
      const allLoadedMs = Date.now() - loadedAt + started.readyMs;
      await sleep(settle);
      const loaded = await loadedNow();
      const sample = processTree(app.pid);
      const entry = { mode, run: run + 1, readyMs: started.readyMs, expectedLoadedMs: allLoadedMs, loaded, expectedLoaded: same(loaded, expected), ...sample };
      report.measure.push(entry);
      save();
      process.stdout.write(`${mode} ${run + 1}: loaded ${loaded.length}, ${sample.count} processes ${JSON.stringify(sample.kinds)}, RSS ${(sample.rssBytes / 2 ** 20).toFixed(0)} MB, footprint ${sample.footprintBytes === null ? "n/a" : (sample.footprintBytes / 2 ** 20).toFixed(0) + " MB"}\n`);
      await app.quit({ timeout: 30000, graceful: true });
      assert.ok(!app.alive, `${mode} ${run + 1} quit`);
      app = null;
    }
  }
}

const syncState = () => evaluate(`const u = acSync.useSync.getState(); return { status: u.status, error: u.error ?? null, lastSyncedAt: u.lastSyncedAt ?? null };`);
const folderListing = (folder) => execFileSync("find", [folder, "-type", "f", "-exec", "stat", "-f", "%N %z %m", "{}", "+"], { encoding: "utf8", timeout: 10000 }).trim().split("\n").filter(Boolean).map((line) => line.slice(folder.length + 1)).sort();
const syncFolder = join(root, "sync-folder");

async function syncFixture(from) {
  const data = join(root, "sync-fixture");
  copyFixture(from, data);
  mkdirSync(syncFolder);
  await start(data, true, { folder: syncFolder });
  await until("every profile loads", async () => same(await loadedNow(), profileIds.map(engineOf)), 60000, 250);
  const on = await evaluate(`return acSync.turnOnSync(${JSON.stringify(syncFolder)});`, 90000);
  assert.deepEqual(on, { ok: true }, `turnOnSync ${JSON.stringify(on)}`);
  for (let i = 0; i < 3; i++) { await evaluate("return acSync.syncNow();", 90000); await sleep(1000); }
  const state = await until("sync settles", async () => { const s = await syncState(); return s.lastSyncedAt && s.status !== "updating" ? s : null; }, 60000, 500);
  const files = folderListing(syncFolder);
  await app.quit({ timeout: 30000, graceful: true });
  assert.ok(!app.alive, "sync fixture instance quit");
  app = null;
  report.syncFixture = { data, state, files: files.length };
  save();
  return data;
}

async function measureSync(from) {
  report.syncMeasure = [];
  for (let run = 0; run < runs; run++) {
    for (const eager of [false, true]) {
      const mode = eager ? "eager+sync" : "lazy+sync";
      const data = join(root, `${eager ? "eager" : "lazy"}-sync-${run + 1}`);
      copyFixture(from, data);
      const started = await start(data, eager, { folder: syncFolder });
      const expected = eager ? profileIds.map(engineOf) : [""];
      await until(`${mode} launch loads`, async () => same(await loadedNow(), expected), 60000, 250);
      await sleep(settle);
      await evaluate("return acSync.syncNow();", 90000);
      const synced = await until(`${mode} sync cycle`, async () => { const s = await syncState(); return s.lastSyncedAt && s.status !== "updating" ? s : null; }, 60000, 500);
      await sleep(2000);
      const loaded = await loadedNow();
      const sample = processTree(app.pid);
      const entry = { mode, run: run + 1, readyMs: started.readyMs, loaded, expectedLoaded: same(loaded, expected), sync: synced, ...sample };
      report.syncMeasure.push(entry);
      save();
      process.stdout.write(`${mode} ${run + 1}: loaded ${loaded.length}, sync ${synced.status}, ${sample.count} processes, footprint ${sample.footprintBytes === null ? "n/a" : (sample.footprintBytes / 2 ** 20).toFixed(0) + " MB"}\n`);
      if (!eager && run === runs - 1) {
        await step("with sync on, an unloaded profile stays pending and syncs once it loads", async () => {
          assert.deepEqual(loaded, [""], "a sync cycle loads no other profile");
          assert.notEqual(synced.status, "stalled", `sync is not stalled by unloaded profiles: ${JSON.stringify(synced)}`);
          const target = profileIds[3];
          const before = folderListing(syncFolder);
          const t0 = Date.now();
          await evaluate(`ac.store.getState().switchProfile("w1", ${JSON.stringify(target)}); return true;`);
          await until(`${target} loads`, async () => (await loadedNow()).includes(engineOf(target)), 30000, 100);
          const after = await until("a sync cycle after the load", async () => { const s = await syncState(); return s.lastSyncedAt > synced.lastSyncedAt && s.status !== "updating" ? s : null; }, 30000, 250);
          const files = folderListing(syncFolder);
          return { syncedAfterLoadMs: Date.now() - t0, before: synced, after, changedFiles: files.filter((f) => !before.includes(f)), loaded: await loadedNow() };
        });
      }
      await app.quit({ timeout: 30000, graceful: true });
      assert.ok(!app.alive, `${mode} ${run + 1} quit`);
      app = null;
    }
  }
}

async function checks(from) {
  const data = join(root, "checks");
  copyFixture(from, data);
  const started = await start(data, false);
  report.checksInstance = { data, pid: started.pid };
  const expected = new Set([""]);
  const expectOnly = async (what) => {
    const loaded = await loadedNow();
    assert.deepEqual(loaded, sorted([...expected]), `${what}: loaded ${JSON.stringify(loaded)}, expected ${JSON.stringify(sorted([...expected]))}`);
    return loaded;
  };
  await until("launch loads Default only", async () => same(await loadedNow(), [...expected]), 60000, 250);

  await step("launch loads only the window's profile", async () => {
    await sleep(settle);
    return { loaded: await expectOnly("after settle"), processes: processTree(app.pid) };
  });

  const libraryOf = (profileId) => evaluate(`const s = ac.store.getState(); const id = ${JSON.stringify(profileId)};
    const nodes = Object.values(s.bookmarks?.nodes ?? {}); const mark = ${JSON.stringify(`${origin}/mark-`)} + id;
    const history = (s.history?.[id] ?? []).map((e) => e.url);
    return { bookmarkRoot: !!s.bookmarks?.roots?.[id], bookmark: nodes.some((n) => n.url === mark), historyReady: !!s.historyReady?.[id], history: history.length,
      visited: history.some((u) => u.endsWith("/tab-" + ${JSON.stringify(String(profileIds.indexOf(profileId)))})) };`);

  await step("passive reads of an unloaded profile start nothing", async () => {
    const target = profileIds[5];
    const library = await libraryOf(target);
    const favicons = await evaluate(`return Object.keys(ac.favicons.useFavicons?.getState?.() ?? {}).length;`);
    await evaluate(`ac.pages.openInternalPage("history", "w1"); return true;`);
    await evaluate(`ac.pages.openInternalPage("bookmarks", "w1"); return true;`);
    await sleep(settle);
    assert.equal(library.bookmark, true, "the unloaded profile's bookmark is in the native projection");
    return { library, favicons, loaded: await expectOnly("after passive reads") };
  });

  const switchTimed = async (profileId, tabId, title) => {
    const t0 = Date.now();
    const engine = engineOf(profileId);
    const committed = await evaluate(`const before = Date.now(); ac.store.getState().switchProfile("w1", ${JSON.stringify(profileId)});
      const s = ac.store.getState(); const rows = s.windows.w1.tabIds.filter((id) => s.tabs[id]?.profileId === ${JSON.stringify(profileId)}).length;
      const commitMs = Date.now() - before;
      return globalThis.expo.modules.SolaraCEF.loadedProfiles().then((loaded) => ({ selected: s.windows.w1.profileId, rows, commitMs, engineLoadedAtCommit: loaded.includes(${JSON.stringify(engine)}) }));`);
    const marks = { evalMs: Date.now() - t0, committed };
    await until(`${profileId} loads`, async () => (await loadedNow()).includes(engine), 30000, 25);
    marks.engineLoadedMs = Date.now() - t0;
    await until(`${profileId} shown in Chrome's window`, async () => (await evaluate(`return globalThis.expo.modules.SolaraCEF.chromeWindows();`)).some((w) => w.profile === engine), 30000, 25);
    marks.chromeShownMs = Date.now() - t0;
    await until(`${tabId} page arrives`, () => evaluate(`return ac.store.getState().tabs[${JSON.stringify(tabId)}]?.title === ${JSON.stringify(title)};`), 30000, 25);
    marks.pageMs = Date.now() - t0;
    return marks;
  };

  await step("first switch to an unloaded profile", async () => {
    const target = profileIds[1];
    const before = await evaluate(`return ac.store.getState().tabs["tab-1"]?.title;`);
    const marks = await switchTimed(target, "tab-1", "/tab-1");
    expected.add(engineOf(target));
    assert.equal(marks.committed.selected, target);
    assert.equal(marks.committed.rows, 2);
    await sleep(settle);
    return { titleBefore: before, ...marks, loaded: await expectOnly("after first switch") };
  });

  await step("return switch starts nothing", async () => {
    await evaluate(`ac.store.getState().switchProfile("w1", "default"); return true;`);
    await until("Default shown", async () => (await evaluate(`return globalThis.expo.modules.SolaraCEF.chromeWindows();`)).some((w) => w.profile === ""), 10000);
    await sleep(settle);
    return { loaded: await expectOnly("after return switch") };
  });

  await step("pinned tab of an unloaded profile", async () => {
    const target = profileIds[2];
    const t0 = Date.now();
    await evaluate(`ac.store.getState().activate("pin-2"); return true;`);
    expected.add(engineOf(target));
    await until("pin-2's profile loads", async () => (await loadedNow()).includes(engineOf(target)), 30000, 25);
    const engineLoadedMs = Date.now() - t0;
    await until("pin-2 page arrives", () => evaluate(`return ac.store.getState().tabs["pin-2"]?.title === "/pin-2";`), 30000, 25);
    const pageMs = Date.now() - t0;
    const shown = await evaluate(`return ac.store.getState().windows.w1.profileId;`);
    await sleep(settle);
    return { engineLoadedMs, pageMs, shownProfile: shown, loaded: await expectOnly("after pinned tab") };
  });

  await step("link opened into an unloaded profile", async () => {
    const target = profileIds[3];
    const t0 = Date.now();
    const tabId = await evaluate(`return ac.store.getState().newTab("w1", { url: ${JSON.stringify(`${origin}/link-3`)}, profileId: ${JSON.stringify(target)}, background: true });`);
    expected.add(engineOf(target));
    await until("link's profile loads", async () => (await loadedNow()).includes(engineOf(target)), 30000, 25);
    const engineLoadedMs = Date.now() - t0;
    await until("link page arrives", () => evaluate(`return ac.store.getState().tabs[${JSON.stringify(tabId)}]?.title === "/link-3";`), 30000, 50);
    const pageMs = Date.now() - t0;
    const tab = await evaluate(`const t = ac.store.getState().tabs[${JSON.stringify(tabId)}]; return { profileId: t.profileId, url: t.url };`);
    assert.equal(tab.profileId, target);
    await sleep(settle);
    return { tabId, engineLoadedMs, pageMs, tab, loaded: await expectOnly("after link") };
  });

  await step("a page link in a newly loaded profile", async () => {
    const page = await app.page("/pin-2");
    try { await page.eval(`document.getElementById("child").click(); true`, { timeout: 5000, userGesture: true }); }
    finally { page.close(); }
    const child = await until("child tab", () => evaluate(`const t = Object.values(ac.store.getState().tabs).find((t) => t.url === ${JSON.stringify(`${origin}/child-pin-2`)}); return t ? { profileId: t.profileId, title: t.title } : null;`), 15000, 100);
    assert.equal(child.profileId, profileIds[2]);
    return { child, loaded: await expectOnly("after page link") };
  });

  await step("history, bookmarks and favicons of a profile arrive once it opens", async () => {
    const target = profileIds[5];
    const before = await libraryOf(target);
    const marks = await switchTimed(target, "tab-5", "/tab-5");
    expected.add(engineOf(target));
    const after = await until("history view of the opened profile", async () => { const l = await libraryOf(target); return l.historyReady && l.visited ? l : null; }, 20000, 200);
    const favicon = await until("favicon of the opened profile", () => evaluate(`return ac.store.getState().tabs["tab-5"]?.favicon ?? null;`), 20000, 200).catch(() => null);
    await evaluate(`ac.store.getState().switchProfile("w1", "default"); return true;`);
    await sleep(settle);
    return { before, after, favicon, ...marks, loaded: await expectOnly("after opening a profile's library") };
  });

  await step("a bookmark added to an unloaded profile", async () => {
    const target = profileIds[4];
    const id = await evaluate(`return ac.bookmarks.addBookmark({ profileId: ${JSON.stringify(target)}, title: "Cold mark", url: ${JSON.stringify(`${origin}/cold-mark`)} });`, 20000);
    const shown = await until("bookmark in the projection", () => evaluate(`return Object.values(ac.store.getState().bookmarks?.nodes ?? {}).some((n) => n.url === ${JSON.stringify(`${origin}/cold-mark`)});`), 20000, 200);
    await sleep(settle);
    const loaded = await loadedNow();
    const loadedForWrite = loaded.includes(engineOf(target));
    if (loadedForWrite) expected.add(engineOf(target));
    return { id, shown, loadedForWrite, loaded: await expectOnly("after a bookmark write") };
  });

  await step("private window of an unloaded profile", async () => {
    const original = profileIds[6];
    const windowId = await evaluate(`return ac.store.getState().createWindow({ incognito: true, profileId: ${JSON.stringify(original)} });`);
    expected.add(engineOf(original));
    const tabId = await evaluate(`return ac.store.getState().newTab(${JSON.stringify(windowId)}, { url: ${JSON.stringify(`${origin}/private-6`)} });`);
    await until("private page arrives", () => evaluate(`return ac.store.getState().tabs[${JSON.stringify(tabId)}]?.title === "/private-6";`), 30000, 100);
    const loadedWhileOpen = await expectOnly("private window open");
    await evaluate(`ac.store.getState().closeWindow(${JSON.stringify(windowId)}); return true;`);
    await until("private window closed", () => evaluate(`return !ac.store.getState().windows[${JSON.stringify(windowId)}];`), 10000);
    await sleep(2000);
    return { windowId, tabId, loadedWhileOpen, loaded: await expectOnly("after private window") };
  });

  await step("deleting an unused, never-loaded profile", async () => {
    const target = profileIds[7];
    const dir = chromiumDir(data, target);
    const existedBefore = existsSync(dir);
    await evaluate(`ac.store.getState().deleteProfile(${JSON.stringify(target)}); return true;`);
    await until("profile gone from the store", () => evaluate(`return !ac.store.getState().profiles[${JSON.stringify(target)}];`), 10000);
    const removed = await until("Chromium data removed", async () => !existsSync(dir), 20000, 250).catch(() => false);
    await sleep(2000);
    assert.ok(existedBefore, `fixture had ${dir}`);
    assert.ok(removed, `${dir} removed`);
    return { dir, existedBefore, removed, loaded: await expectOnly("after deletion") };
  });

  await step("setting on loads every remaining profile", async () => {
    await evaluate(`ac.store.getState().updateSettings({ loadAllProfilesAtLaunch: true }); return true;`);
    for (const id of profileIds.slice(0, 7)) expected.add(engineOf(id));
    await until("all remaining profiles load", async () => same(await loadedNow(), [...expected]), 30000, 100);
    await evaluate(`ac.store.getState().updateSettings({ loadAllProfilesAtLaunch: false }); return true;`);
    return { loaded: await expectOnly("after setting") };
  });

  await step("quit is graceful", async () => {
    const { pid, launchedAt } = app;
    const result = await app.quit({ timeout: 30000, graceful: true });
    assert.equal(result?.how, "quit", `quit ended by ${result?.how}`);
    app = null;
    const crashes = crashReportsForInstance(data, pid, launchedAt);
    assert.deepEqual(crashes, []);
    return { pid, how: result.how, crashes };
  });

  await step("relaunch loads only the window's profile", async () => {
    const relaunched = await start(data, false, { fresh: false });
    const windowProfile = await evaluate(`return ac.store.getState().windows.w1?.profileId ?? null;`);
    const want = sorted(["", engineOf(windowProfile ?? "default")]);
    await until("relaunch loads", async () => (await loadedNow()).includes(want.at(-1)), 60000, 250);
    await sleep(settle);
    const loaded = await loadedNow();
    assert.deepEqual(loaded, want);
    const profiles = await evaluate(`return ac.store.getState().profileOrder;`);
    assert.ok(!profiles.includes(profileIds[7]), "deleted profile stays deleted");
    assert.ok(!existsSync(chromiumDir(data, profileIds[7])), "deleted profile's data stays gone");
    const { pid, launchedAt } = app;
    const result = await app.quit({ timeout: 30000, graceful: true });
    assert.equal(result?.how, "quit", `relaunch quit ended by ${result?.how}`);
    app = null;
    const crashes = crashReportsForInstance(data, pid, launchedAt);
    assert.deepEqual(crashes, []);
    return { readyMs: relaunched.readyMs, windowProfile, loaded, profiles, how: result.how, crashes };
  });
}

async function webkitInUnloadedProfile(from) {
  const data = join(root, "webkit-unloaded");
  copyFixture(from, data);
  const target = profileIds[3];
  const tabId = "wk-unloaded";
  app = await launch(appPath, { data, onboarded: true, probe: true, keepData: true, startTimeout: 60000, env,
    session: session({
      profiles: profileIds.map((id, index) => ({ id, name: `Profile ${index + 1}` })),
      windows: [{ id: "w1", profileId: "default", activeTabIds: { default: "wk-default", [target]: tabId } }],
      tabs: [
        { id: "wk-default", profileId: "default", url: `${origin}/webkit-default`, title: "WebKit", engine: "webkit" },
        { id: tabId, profileId: target, url: `${origin}/webkit-unloaded`, title: "WebKit", engine: "webkit" },
      ],
      settings: { pageEngine: "webkit", loadAllProfilesAtLaunch: false, warnBeforeClosingLastTab: false, warnBeforeClosingWindow: false, cliControl: false },
    }),
    ready: { timeout: 180000, test: "return !!ac.store && !!ac.store.getState().windows.w1;" } });
  await step("a WebKit-only profile gets WebKit blocking, with the blocker's state read from Default", async () => {
    const status = () => evaluate(`return globalThis.expo.modules.SolaraCEF.devWebKitBlockerStatus("127.0.0.1");`);
    const ready = await until("the WebKit blocker is ready", async () => { const s = await status(); return s.ready && !s.preparing ? s : null; }, 150000, 500);
    const atLaunch = await loadedNow();
    const hiddenPage = await evaluate(`return !!ac.webviews.get(${JSON.stringify(tabId)});`);
    await evaluate(`ac.store.getState().switchProfile("w1", ${JSON.stringify(target)}); return true;`);
    await until("the WebKit page of the switched-to profile is up", () => evaluate(`return !!ac.webviews.get(${JSON.stringify(tabId)});`), 30000, 250);
    const loadedWhenShown = await loadedNow();
    const inject = (src) => evaluate(`return ac.webviews.get(${JSON.stringify(tabId)}).evaluate(${JSON.stringify(`(() => { const s = document.createElement('script'); s.src = '${src}'; document.head.appendChild(s); return true; })()`)});`, 20000);
    await inject("/allowed.js?tag=webkit-unloaded");
    await inject("/xpopup/xpopup.js?tag=webkit-unloaded");
    await sleep(2500);
    assert.deepEqual(atLaunch, [""], "a WebKit-only launch loads only Default in Chromium");
    assert.equal(hiddenPage, false, "a WebKit tab of a profile no window shows has no page yet");
    assert.ok(scriptHits.includes("/allowed.js?tag=webkit-unloaded"), "the page's own script loads");
    assert.equal(scriptHits.includes("/xpopup/xpopup.js?tag=webkit-unloaded"), false, "the ad script is blocked");
    return { atLaunch, hiddenPage, loadedWhenShown, targetLoadedInChromium: loadedWhenShown.includes(engineOf(target)),
      blocker: { ready: ready.ready, generation: ready.generation, enabled: ready.enabled }, hits: scriptHits.filter((u) => u.includes("webkit-unloaded")) };
  });
  await app.quit({ timeout: 30000, graceful: true });
  app = null;
}

try {
  const from = await fixture();
  await measure(from);
  await measureSync(await syncFixture(from));
  await checks(from);
  await webkitInUnloadedProfile(from);
  const all = () => [...report.measure, ...report.syncMeasure];
  const pick = (mode, key) => all().filter((m) => m.mode === mode).map((m) => m[key]);
  const median = (list) => { const s = [...list].filter((v) => v !== null).sort((a, b) => a - b); return s.length ? s[Math.floor((s.length - 1) / 2)] : null; };
  report.summary = Object.fromEntries(["lazy", "eager", "lazy+sync", "eager+sync"].map((mode) => [mode, {
    loaded: pick(mode, "loaded").map((l) => l.length), processes: pick(mode, "count"), rssMB: pick(mode, "rssBytes").map((b) => Math.round(b / 2 ** 20)),
    footprintMB: pick(mode, "footprintBytes").map((b) => (b === null ? null : Math.round(b / 2 ** 20))),
    medianFootprintMB: median(pick(mode, "footprintBytes")) === null ? null : Math.round(median(pick(mode, "footprintBytes")) / 2 ** 20),
    medianRssMB: Math.round(median(pick(mode, "rssBytes")) / 2 ** 20),
  }]));
  const failed = report.checks.filter((c) => !c.ok).map((c) => c.name);
  const unexpected = all().filter((m) => !m.expectedLoaded).map((m) => `${m.mode} ${m.run}`);
  report.status = failed.length || unexpected.length ? `failed: ${[...failed, ...unexpected.map((u) => `${u} loaded set`)].join(", ")}` : "passed";
  save();
  process.stdout.write(`${JSON.stringify(report.summary)}\n${report.status}; evidence ${out}\n`);
  process.exitCode = report.status === "passed" ? 0 : 1;
} catch (error) {
  report.status = "failed";
  report.error = error.stack ?? String(error);
  save();
  process.stderr.write(`${report.error}\nevidence ${out}\n`);
  process.exitCode = 1;
} finally {
  if (app) await app.quit({ timeout: 30000, graceful: true }).catch(() => {});
  await new Promise((done) => server.close(done));
}

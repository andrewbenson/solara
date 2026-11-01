#!/usr/bin/env node
import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { createHash } from "node:crypto";
import { existsSync, mkdtempSync, readFileSync, realpathSync, rmSync, statSync, writeFileSync } from "node:fs";
import { createServer } from "node:http";
import { homedir, tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const CHECKS = {
  "delete-loaded": "Loaded Chromium stays queued until restart; WebKit removed now; two relaunches keep A gone and survivors intact",
  "delete-unloaded": "Materialize A, quit, pre-JS production delete without loading A: queue drains in-session; relaunch keeps A gone",
  "crash-before-relaunch": "Crash with loaded Chromium pending restart; first unarmed launch drains the durable orphan and preserves survivors",
  "crash-after-tombstone": "Crash after reserve, recover the durable orphan on an unarmed launch",
  default: "Shared Default remains live; its final reference clears data but retains Chromium/Default",
};
const pause = (ms) => new Promise((done) => setTimeout(done, ms));
const json = JSON.stringify;
const engineOf = (profile) => (profile.dataId ?? profile.id) === "default" ? "" : (profile.dataId ?? profile.id);
const remaining = (deadline, cap) => {
  const ms = Math.min(cap, deadline - Date.now());
  if (ms <= 0) throw new Error("outer check deadline exceeded");
  return ms;
};

export function parseChecks(args) {
  for (const arg of args) assert.ok(Object.hasOwn(CHECKS, arg), `unknown check ${arg} (--list)`);
  return args.length ? [...new Set(args)] : Object.keys(CHECKS);
}

export function webkitIdentifier(data, engine) {
  const bytes = createHash("sha256").update(`solara.webkit|${data}|${engine}`).digest().subarray(0, 16);
  bytes[6] = (bytes[6] & 15) | 80;
  bytes[8] = (bytes[8] & 63) | 128;
  const hex = bytes.toString("hex");
  return [hex.slice(0, 8), hex.slice(8, 12), hex.slice(12, 16), hex.slice(16, 20), hex.slice(20)].join("-");
}

export function retiredEngines(ledger) {
  if (Array.isArray(ledger) && ledger.every((id) => typeof id === "string")) return ledger;
  assert.ok(ledger && Array.isArray(ledger.deleted) && Array.isArray(ledger.reserved), "invalid deletion ledger");
  const all = [...ledger.deleted, ...ledger.reserved];
  assert.ok(all.every((id) => typeof id === "string"), "invalid deletion ledger names");
  return all;
}

export function pendingRestartLogged(output, engine) {
  const marker = `[store] couldn't delete profile data (${engine}): `;
  return output.split("\n").some((line) => {
    const at = line.indexOf(marker);
    return at >= 0 && line.slice(at + marker.length).trim() === "Chromium deletion pending restart";
  });
}

export function reportLeftovers(paths, say, exists = existsSync) {
  const leftovers = [...new Set(paths)].filter((path) => exists(path)).sort();
  for (const path of leftovers) say(`[profile-delete] leftover ${path}`);
  return leftovers;
}

export function assertPendingCrash(record, output, exists = existsSync) {
  assert.ok(output.split("\n").some((line) => line.trim() === `[profile-delete] point pending-restart ${record.dirs.engine}`), "target pending-restart crash hook fired");
  assert.ok(pendingRestartLogged(output, record.dirs.engine), "target Chromium completed with only pending restart");
  assert.ok(exists(record.dirs.chromium), "Chromium directory still needs deletion after crash");
  for (const path of record.dirs.webkit) assert.ok(!exists(path), `WebKit removed before pending-restart crash: ${path}`);
}

export function assertRetired(state, record) {
  assert.ok(!state.profiles[record.profile.id], "deleted profile absent from native store");
  assert.ok(!Object.values(state.profiles).some((p) => p.id === record.profile.id || engineOf(p) === record.dirs.engine), "no live profile reuses retired profile or data identity");
}

export async function waitFor(what, read, { timeout = 10000, alive = () => true } = {}) {
  const deadline = Date.now() + timeout;
  let last;
  let lastError;
  while (Date.now() < deadline) {
    assert.ok(alive(), `${what}: app exited`);
    let expiration, monitor;
    let expired = false;
    try {
      last = await Promise.race([
        Promise.resolve().then(() => read(remaining(deadline, 3000))),
        new Promise((_done, fail) => {
          expiration = setTimeout(() => { expired = true; fail(new Error(`${what}: deadline after ${timeout} ms`)); }, remaining(deadline, timeout));
          monitor = setInterval(() => {
            try { assert.ok(alive(), `${what}: app exited`); } catch (error) { fail(error); }
          }, 50);
        }),
      ]);
    } catch (error) {
      if (expired || error.appDied || !alive()) throw error;
      last = undefined;
      lastError = error.message;
    } finally {
      clearTimeout(expiration);
      clearInterval(monitor);
    }
    assert.ok(alive(), `${what}: app exited`);
    if (last) return last;
    await pause(Math.min(75, Math.max(0, deadline - Date.now())));
  }
  throw new Error(`${what}: deadline after ${timeout} ms; last ${json(last)}${lastError ? `; last error ${lastError}` : ""}`);
}

export class Run {
  constructor(ctx, data) {
    Object.assign(this, ctx);
    this.data = data;
    this.app = null;
    this.deadline = Date.now() + 120000;
    this.webkitPaths = new Set();
  }
  time(cap = 3000) { return remaining(this.deadline, cap); }
  alive = () => !!this.app?.alive;
  eval(body, timeout = 3000) {
    assert.ok(this.alive(), "app exited before eval");
    return this.app.eval(`const S = () => ac.store.getState(); const N = globalThis.expo.modules.SolaraStoreAdapter; ${body}`, { timeout: this.time(timeout) });
  }
  wait(what, read, timeout = 10000) {
    return waitFor(what, read, { timeout: this.time(timeout), alive: this.alive });
  }
  async start(crashPoint = "", fresh = false, deleteUnloaded = "") {
    this.app = await this.launch(this.appPath, {
      data: this.data, keepData: true, onboarded: true, probe: true, ready: false,
      startTimeout: this.time(20000), js: "live",
      ...(fresh ? { session: this.session({ windows: [{ id: "w1" }], settings: { warnBeforeClosingLastTab: false, warnBeforeClosingWindow: false } }) } : {}),
      env: { SOLARA_NATIVE_SCOPE: "everything", SOLARA_NATIVE_SHELL: "1", SOLARA_SHELL_PANES: "1", SOLARA_NATIVE_PAGES_POOL: "1", SOLARA_TAB_POOL: "1", SOLARA_TEST_KEYCHAIN: "file", SOLARA_TEST_REKEY: "1", SOLARA_TEST_PROFILE_DELETE_CRASH: crashPoint, SOLARA_TEST_PROFILE_DELETE_UNLOADED: deleteUnloaded, SOLARA_TEST_REKEY_CRASH: "", SOLARA_TEST_REKEY_FAIL_AFTER_KEY: "", SOLARA_TEST_KEYCHAIN_FAIL: "" },
    });
    this.data = realpathSync(this.data);
    await this.wait("native workspace and UI harness", (timeout) => this.eval(`return typeof ac !== "undefined" && !!ac.store && !!N;`, timeout), 20000);
    const status = await this.eval(`return N.status();`);
    assert.ok(status.active && status.scope === "everything" && !status.safeMode, `native workspace required: ${json(status)}`);
    const info = await this.eval(`return globalThis.expo.modules.SolaraApp.systemInfo();`);
    assert.equal(info.configuration, "Debug", "pass a Debug app");
    this.bundleId = info.bundleId;
    await this.native();
    assert.equal(await this.eval(`return globalThis.expo.modules.SolaraTabPool.available();`), true, "native pool serves both engines");
    this.window = await this.wait("main window", (timeout) => this.eval(`return Object.keys(S().windows).find((id) => !S().windows[id].incognito) ?? false;`, timeout));
  }
  async native() {
    const snapshot = await this.eval(`return JSON.parse(N.snapshot());`);
    assert.ok(snapshot?.data?.profiles && Array.isArray(snapshot.data.orphanedProfileData), "native snapshot lacks workspace data");
    if (this.bundleId) for (const profile of Object.values(snapshot.data.profiles)) this.directories(profile);
    return snapshot.data;
  }
  async profilesMatch() {
    const native = await this.native();
    await this.wait("ProbeHost profile identities match native store", async (timeout) => {
      const probe = await this.app.snapshot({ fields: ["root.profiles"] }, { timeout });
      const expected = Object.values(native.profiles).map((p) => [p.id, p.name, p.dataId ?? p.id]).sort();
      const actual = probe.profiles.map((p) => [p.id, p.name, p.dataId]).sort();
      return probe.consistent && json(expected) === json(actual);
    });
    return native;
  }
  async create(name, shareWith) {
    const id = await this.eval(`return S().createProfile(${json({ name, ...(shareWith ? { shareWith } : {}) })});`);
    const state = await this.profilesMatch();
    assert.equal(state.profiles[id]?.name, name);
    return state.profiles[id];
  }
  directories(profile) {
    const engine = engineOf(profile);
    const identifier = webkitIdentifier(this.data, engine);
    const library = join(homedir(), "Library", "WebKit");
    const webkit = [join(library, "WebsiteDataStore", identifier), join(library, this.bundleId, "WebsiteDataStore", identifier)];
    for (const path of webkit) this.webkitPaths.add(path);
    return { engine, chromium: join(this.data, "Chromium", engine ? `Profile ${engine}` : "Default"), webkit };
  }
  async page(profile, engine, suffix) {
    return this.eval(`const id = S().newTab(${json(this.window)}, { profileId: ${json(profile.id)}, url: "solara://newtab" });
      S().updateTab(id, { engine: ${json(engine)}, navigation: { url: ${json(`${this.origin}/${suffix}`)}, seq: 1, fresh: true } });
      S().switchProfile(${json(this.window)}, ${json(profile.id)}); S().activate(id); return id;`);
  }
  async readPage(tab, expression, suffix) {
    await this.eval(`S().switchProfile(${json(this.window)}, S().tabs[${json(tab)}].profileId); S().activate(${json(tab)}); return true;`);
    await this.wait(`page ${suffix}`, (timeout) => this.eval(`const p = ac.webviews.get(${json(tab)}); return p ? p.evaluate(${json(`post('result', JSON.stringify(location.href === ${json(`${this.origin}/${suffix}`)} && document.readyState === 'complete'))`)}) : false;`, timeout));
    return this.eval(`return ac.webviews.get(${json(tab)}).evaluate(${json(`post('result', JSON.stringify(${expression}))`)});`);
  }
  async seed(profile, name) {
    const record = { profile, name, dirs: this.directories(profile), pages: {} };
    for (const engine of ["chromium", "webkit"]) {
      const suffix = `${name}-${engine}`;
      const tab = await this.page(profile, engine, suffix);
      const value = `${name}:${engine}`;
      const planted = await this.readPage(tab, `(() => { document.cookie = 'g6=${value}; Path=/; Max-Age=86400; SameSite=Lax'; localStorage.setItem('g6', '${value}'); return { cookie: document.cookie, storage: localStorage.getItem('g6') }; })()`, suffix);
      const live = await this.eval(`return globalThis.expo.modules.SolaraTabPool.livePages();`);
      assert.equal(live.find((page) => page.tabId === tab)?.engine, engine, `${suffix} uses its requested native engine`);
      assert.equal(planted.storage, value);
      assert.ok(planted.cookie.split("; ").includes(`g6=${value}`));
      record.pages[engine] = { tab, suffix, value };
    }
    await this.wait(`${name} engine directories materialized`, async () => existsSync(record.dirs.chromium) && record.dirs.webkit.some(existsSync));
    record.presentWebKit = record.dirs.webkit.filter(existsSync);
    this.rep.log(`${name} directories`, record.dirs);
    await this.intact(record);
    return record;
  }
  async intact(record) {
    assert.ok(existsSync(record.dirs.chromium), `${record.name} Chromium directory retained`);
    for (const path of record.presentWebKit) assert.ok(existsSync(path), `${record.name} WebKit directory retained: ${path}`);
    for (const { tab, suffix, value } of Object.values(record.pages)) {
      const data = await this.readPage(tab, "({ cookie: document.cookie, storage: localStorage.getItem('g6') })", suffix);
      assert.equal(data.storage, value, `${suffix} localStorage`);
      assert.ok(data.cookie.split("; ").includes(`g6=${value}`), `${suffix} cookie: ${data.cookie}`);
    }
  }
  ledger() { return retiredEngines(JSON.parse(readFileSync(join(this.data, "profile-data-tombstones.json"), "utf8"))); }
  async flush() { assert.equal(await this.eval(`return N.flush(2);`, 4000), "saved", "native store durably flushed"); }
  async remove(profile) { await this.eval(`S().deleteProfile(${json(profile.id)}); return true;`); }
  async drained(engine) {
    await this.wait(`orphan ${engine || "Default"} acknowledged by native cleanup`, async () => {
      const state = await this.native();
      return !state.orphanedProfileData.includes(engine) && state;
    }, 15000);
  }
  async loaded(record) {
    await this.intact(record);
    const pages = await this.eval(`return globalThis.expo.modules.SolaraTabPool.livePages();`);
    for (const [engine, { tab }] of Object.entries(record.pages)) {
      assert.equal(pages.find((page) => page.tabId === tab)?.engine, engine, `A has a live ${engine} page before deletion`);
    }
  }
  async queued(record) {
    const state = await this.native();
    assertRetired(state, record);
    assert.ok(state.orphanedProfileData.includes(record.dirs.engine), "deleted data queued before engine acknowledgement");
    assert.ok(this.ledger().includes(record.dirs.engine), "deleted identity retired immediately");
  }
  async webkitGone(record) {
    for (const path of record.dirs.webkit) assert.ok(!existsSync(path), `deleted WebKit directory absent: ${path}`);
    assert.equal(await this.eval(`return globalThis.expo.modules.SolaraWebKit.devStoreExists(${json(record.dirs.engine)});`), false, "WebKit identifier removed");
  }
  async pendingLoaded(record) {
    await this.wait("loaded Chromium cleanup completed pending restart", async () => pendingRestartLogged(this.app.output(), record.dirs.engine), 15000);
    await this.queued(record);
    await this.webkitGone(record);
  }
  async startupDeleted(record) {
    assert.ok(this.app.output().split("\n").some((line) => line.trim().endsWith(`[profile-delete] point delete-unloaded ${record.profile.id}`)), "unloaded profile deleted by production command before JS startup services");
    assertRetired(await this.native(), record);
    assert.ok(this.ledger().includes(record.dirs.engine), "unloaded profile identity retired");
  }
  async closePages(record, fallback) {
    await this.eval(`S().reorderProfiles([${json(record.profile.id)}, ...S().profileOrder.filter(id => id !== ${json(record.profile.id)})]);
      S().switchProfile(${json(this.window)}, ${json(fallback.profile.id)});
      S().closeTabs(Object.values(S().tabs).filter(t => t.profileId === ${json(record.profile.id)}).map(t => t.id), { lastClosesWindow: false }); return true;`);
    await this.pagesClosed(record);
  }
  async pagesClosed(record) {
    const state = await this.native();
    assert.ok(!Object.values(state.tabs).some((tab) => tab.profileId === record.profile.id), "A has no tabs to restore");
    assert.ok(!Object.values(state.windows).some((window) => window.profileId === record.profile.id), "A is not selected");
    assert.equal(state.profileOrder.indexOf(record.profile.id), 0, "A is outside the selected profile's prepared neighbour");
    await this.wait("A has no live pooled pages", async () => {
      const pages = await this.eval(`return globalThis.expo.modules.SolaraTabPool.livePages();`);
      return !pages.some((page) => Object.values(record.pages).some(({ tab }) => tab === page.tabId));
    });
    assert.ok(existsSync(record.dirs.chromium), "A's materialized Chromium directory exists before quitting");
    for (const path of record.presentWebKit) assert.ok(existsSync(path), "A's WebKit directory exists before quitting");
  }
  async gone(record) {
    const state = await this.profilesMatch();
    assertRetired(state, record);
    assert.ok(!existsSync(record.dirs.chromium), "deleted Chromium directory absent");
    await this.webkitGone(record);
    assert.ok(this.ledger().includes(record.dirs.engine), "deleted id remains retired in ledger");
    assert.deepEqual(state.orphanedProfileData, [], "nothing queued");
  }
  async unused(record) {
    const created = await this.create("A", record.profile.id);
    assert.notEqual(created.id, record.profile.id, "profile id never reused");
    assert.notEqual(engineOf(created), record.dirs.engine, "data id never reused");
    assertRetired(await this.profilesMatch(), record);
  }
  async quit() {
    if (!this.app) return;
    const app = this.app;
    if (app.alive) {
      execFileSync("osascript", ["-l", "JavaScript", "-e", `ObjC.import("AppKit"); const a = $.NSRunningApplication.runningApplicationWithProcessIdentifier(${app.pid}); a.isNil() ? "none" : a.terminate`], { timeout: 5000 });
      await waitFor("graceful quit", async () => app.exited, { timeout: 10000 });
    }
    assert.ok(app.exited, "quit must not fall back to a signal");
    await app.quit();
    this.app = null;
  }
  async crashed(record, point) {
    await waitFor(`${point} crash`, async () => this.app.exited, { timeout: this.time(15000) });
    assert.ok(this.app.output().split("\n").some((line) => line.trim() === `[profile-delete] point ${point}${point === "pending-restart" ? ` ${record.dirs.engine}` : ""}`), "app exited through the armed crash hook");
    assert.ok(this.ledger().includes(record.dirs.engine), "ledger was written before crash");
    const { DatabaseSync } = await import("node:sqlite");
    const persisted = new DatabaseSync(join(this.data, "solara.sqlite"), { readOnly: true });
    try {
      const queue = JSON.parse(persisted.prepare("SELECT value FROM workspace WHERE key = 'orphanedProfileData'").get().value);
      assert.ok(queue.includes(record.dirs.engine), "orphan survives on disk at crash point");
      assert.equal(persisted.prepare("SELECT count(*) AS n FROM profile WHERE id = ?").get(record.profile.id).n, 0, "profile deletion durable before crash");
    } finally { persisted.close(); }
    if (point === "pending-restart") assertPendingCrash(record, this.app.output());
    else {
      assert.ok(existsSync(record.dirs.chromium), "crash happened before Chromium deletion");
      for (const path of record.presentWebKit) assert.ok(existsSync(path), "crash happened before WebKit deletion");
    }
  }
  leftovers() { return reportLeftovers(this.webkitPaths, (line) => this.rep.say(line)); }
}

async function setup(run) {
  await run.start("", true);
  const A = await run.create("A");
  const B = await run.create("B");
  const state = await run.native();
  return {
    A: await run.seed(A, "A"), B: await run.seed(B, "B"), Default: await run.seed(state.profiles.default, "Default"),
  };
}

async function preserved(run, fixture) {
  await run.intact(fixture.B);
  await run.intact(fixture.Default);
}

async function relaunched(run, fixture, retired) {
  await run.flush();
  await run.quit();
  await run.start();
  await run.drained(fixture.A.dirs.engine);
  await run.gone(fixture.A);
  await preserved(run, fixture);
  assert.deepEqual(run.ledger(), retired, "relaunch keeps the ledger");
  await run.unused(fixture.A);
  await run.gone(fixture.A);
}

export async function deletionScenario(run, fixture, loaded) {
  if (loaded) {
    await run.loaded(fixture.A);
    await run.remove(fixture.A.profile);
    await run.queued(fixture.A);
    await run.flush();
    await run.pendingLoaded(fixture.A);
  } else {
    await run.closePages(fixture.A, fixture.B);
    await run.flush();
    await run.quit();
    await run.start("", false, fixture.A.profile.id);
    await run.startupDeleted(fixture.A);
    await run.drained(fixture.A.dirs.engine);
    await run.gone(fixture.A);
  }
  await preserved(run, fixture);
  await run.unused(fixture.A);
  if (loaded) await run.pendingLoaded(fixture.A);
  else await run.gone(fixture.A);
  const retired = run.ledger();
  await relaunched(run, fixture, retired);
  if (loaded) await relaunched(run, fixture, retired);
}

export async function crashBeforeRelaunch(run, fixture) {
  await run.flush();
  await run.quit();
  await run.start("pending-restart");
  await run.loaded(fixture.A);
  await preserved(run, fixture);
  await run.remove(fixture.A.profile).catch((error) => {
    if (!error.appDied && !run.app.exited) throw error;
  });
  await run.crashed(fixture.A, "pending-restart");
  const retired = run.ledger();
  await run.quit();
  await run.start();
  await run.drained(fixture.A.dirs.engine);
  await run.gone(fixture.A);
  await preserved(run, fixture);
  assert.deepEqual(run.ledger(), retired, "crash recovery keeps the retired identity");
  await run.unused(fixture.A);
  await run.gone(fixture.A);
  await relaunched(run, fixture, retired);
}

async function check(run, name) {
  const fixture = await setup(run);
  if (name === "delete-loaded" || name === "delete-unloaded") {
    await deletionScenario(run, fixture, name === "delete-loaded");
  } else if (name === "crash-before-relaunch") {
    await crashBeforeRelaunch(run, fixture);
  } else if (name === "crash-after-tombstone") {
    await run.flush();
    await run.quit();
    await run.start("after-ledger");
    await run.intact(fixture.A);
    await run.intact(fixture.B);
    await run.remove(fixture.A.profile).catch((error) => {
      if (!error.appDied && !run.app.exited) throw error;
    });
    await run.crashed(fixture.A, "after-ledger");
    await run.quit();
    await run.start();
    await run.drained(fixture.A.dirs.engine);
    await run.gone(fixture.A);
    await run.intact(fixture.B);
    await run.intact(fixture.Default);
    await run.unused(fixture.A);
  } else {
    const shared = await run.create("Shared Default", "default");
    assert.equal(engineOf(shared), "");
    await run.remove(shared);
    assert.ok((await run.profilesMatch()).profiles.default, "live Default reference retained");
    assert.deepEqual((await run.native()).orphanedProfileData, [], "shared deletion queues no data");
    assert.ok(!existsSync(join(run.data, "profile-data-tombstones.json")) || !run.ledger().includes(""), "shared Default not retired");
    await run.intact(fixture.Default);
    await run.intact(fixture.B);
    const before = statSync(fixture.Default.dirs.chromium);
    await run.remove(fixture.Default.profile);
    await run.drained("");
    const state = await run.profilesMatch();
    assert.ok(!state.profiles.default, "last Default-backed profile deleted");
    assert.ok(!Object.values(state.profiles).some((p) => engineOf(p) === ""));
    assert.ok(run.ledger().includes(""), "Default engine identity retired");
    const after = statSync(fixture.Default.dirs.chromium);
    assert.equal(after.ino, before.ino, "deleteDefault clears Chromium data in place");
    assert.equal(after.dev, before.dev, "Default directory retained");
    for (const path of fixture.Default.dirs.webkit) assert.ok(!existsSync(path), `Default WebKit removed: ${path}`);
    assert.equal(await run.eval(`return globalThis.expo.modules.SolaraWebKit.devStoreExists("");`), false);
    const { DatabaseSync } = await import("node:sqlite");
    const cookiesFile = [join(fixture.Default.dirs.chromium, "Cookies"), join(fixture.Default.dirs.chromium, "Network", "Cookies")].find(existsSync);
    assert.ok(cookiesFile, "materialized Default cookie database remains inspectable");
    const db = new DatabaseSync(cookiesFile, { readOnly: true });
    try { assert.equal(db.prepare("SELECT count(*) AS n FROM cookies WHERE host_key = ? AND name = 'g6'").get("127.0.0.1").n, 0, "Default cookie erased"); }
    finally { db.close(); }
    await run.intact(fixture.B);
    await run.intact(fixture.A);
    assert.deepEqual(state.orphanedProfileData, []);
  }
  await run.flush();
  return { deleted: fixture.A.profile.id, B: fixture.B.profile.id, directories: fixture.A.dirs };
}

async function main(args) {
  if (args.includes("--list")) {
    for (const [name, description] of Object.entries(CHECKS)) console.log(`${name.padEnd(24)}${description}`);
    return;
  }
  const [appArg, ...selected] = args;
  assert.ok(appArg && !appArg.startsWith("--"), "usage: node profile-delete-e2e.mjs <Debug app> [check...] (--list)");
  const names = parseChecks(selected);
  const appPath = realpathSync(resolve(appArg));
  assert.ok(!appPath.startsWith("/Applications/") && !appPath.includes("/apps/browser/build-vista/"), "pass an isolated Debug build");
  const { launch, reporter, session, holdUiGate, uiGateKey } = await import("../../../scripts/lib/instance.mjs");
  await holdUiGate(uiGateKey(appPath));
  const scratch = realpathSync(mkdtempSync(join(tmpdir(), "ac-profile-delete-")));
  const rep = reporter(join(scratch, "profile-delete-e2e.log"), { name: "profile-delete-e2e" });
  const server = createServer((_req, res) => {
    res.writeHead(200, { "content-type": "text/html", "cache-control": "no-store" });
    res.end("<!doctype html><title>G6 profile storage</title><body>G6 profile storage</body>");
  });
  try {
    await Promise.race([
      new Promise((done, fail) => { server.once("error", fail); server.listen(0, "127.0.0.1", done); }),
      pause(3000).then(() => { throw new Error("local server listen deadline"); }),
    ]);
    const origin = `http://127.0.0.1:${server.address().port}`;
    for (const name of names) {
      const run = new Run({ appPath, origin, launch, reporter, rep, session }, join(scratch, name));
      let leftovers = [];
      const passed = await rep.check(name, async () => {
        try { return await check(run, name); }
        finally {
          try { await run.quit(); }
          finally { leftovers = run.leftovers(); }
        }
      });
      rep.results.at(-1).leftovers = leftovers;
      if (passed) rmSync(run.data, { recursive: true, force: true });
      else rep.say(`${name} evidence retained: ${run.data}`);
      if (run.app && !run.app.exited) {
        rep.say(`graceful quit failed; stopping with instance evidence at ${run.data}`);
        break;
      }
    }
  } finally {
    server.closeAllConnections();
    server.close();
  }
  writeFileSync(join(scratch, "results.json"), json(rep.results));
  process.exitCode = rep.summary() ? 0 : 1;
  const leftovers = rep.results.flatMap((result) => result.leftovers.map((path) => ({ check: result.name, path })));
  rep.say(`[profile-delete] leftover summary: ${leftovers.length} WebKit directories`);
  for (const { check, path } of leftovers) rep.say(`  ${check}: ${path}`);
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  await main(process.argv.slice(2)).catch((error) => { console.error(error.stack ?? error); process.exitCode = 1; });
}

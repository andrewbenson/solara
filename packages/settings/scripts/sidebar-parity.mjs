#!/usr/bin/env node
import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import fs from "node:fs";
import { createHash } from "node:crypto";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { compare, canonical, facts } from "./sidebar-oracle.mjs";
import { launch, session, sleep, wipeRefusal } from "../../../scripts/lib/instance.mjs";

const [appArg, scratchArg] = process.argv.slice(2);
if (!appArg || !scratchArg) throw new Error("usage: sidebar-parity.mjs <Debug.app> <fresh scratch>");
const app = path.resolve(appArg), scratch = path.resolve(scratchArg);
if (app.startsWith("/Applications/") || fs.existsSync(scratch)) throw new Error("use an owned Debug app and a new scratch directory");
const refusal = wipeRefusal(scratch);
if (refusal) throw new Error(refusal);
fs.mkdirSync(scratch, { recursive: true });
const manifest = JSON.parse(fs.readFileSync(new URL("./sidebar-parity-cases.json", import.meta.url), "utf8"));
const chosen = process.argv.slice(4).find((argument) => argument.startsWith("--case="))?.slice(7);
const cases = chosen ? manifest.cases.filter((entry) => entry.name === chosen) : manifest.cases;
if (!cases.length) throw new Error("unknown acceptance case");
const started = Date.now();

function sourceHash(root) {
  const hash = createHash("sha256");
  function visit(directory) {
    for (const name of fs.readdirSync(directory).sort()) {
      const file = path.join(directory, name);
      if (fs.statSync(file).isDirectory()) visit(file);
      else { hash.update(path.relative(root, file)); hash.update(fs.readFileSync(file)); }
    }
  }
  visit(root);
  return hash.digest("hex");
}

async function bounded(inst, work, predicate, label, milliseconds = 45000) {
  const end = Date.now() + milliseconds;
  let value;
  while (Date.now() < end) {
    if (Date.now() - started > 30 * 60 * 1000) throw new Error("acceptance driver exceeded thirty minutes");
    try { process.kill(inst.pid, 0); } catch { throw new Error(`instance exited while waiting for ${label}`); }
    value = await work();
    if (predicate(value)) return value;
    await sleep(100);
  }
  throw new Error(`${label} timed out: ${JSON.stringify(value)}`);
}

async function snapshot(inst, testCase) {
  const raw = await inst.eval(`
    const s = ac.store.getState();
    const settings = expo.modules.SolaraSettings;
    const core = expo.modules.SolaraCEF;
    const wanted = ${JSON.stringify(manifest.iconPages)};
    const bookmarks = {}, history = {}, nativeIcons = {}, cache = {};
    function bookmarkSnapshot(id, attempt) {
      const book = settings.bookmarkWriterSnapshot(id);
      if (book.ready && book.hasView) return Promise.resolve(book);
      return new Promise(function(done) { setTimeout(done, 20); }).then(function() {
        return attempt < 99 ? bookmarkSnapshot(id, attempt + 1) : book;
      });
    }
    return s.profileOrder.reduce(function(pending, id) {
      return pending.then(function() {
        const dataId = s.profiles[id].dataId ?? id;
        const engine = dataId === "default" ? "" : dataId;
        return Promise.resolve(core.ensureProfile(engine)).then(function(loaded) {
          if (!loaded) throw new Error("profile did not load");
          return core.engineCall("ac_favicons_get", engine, JSON.stringify({ pages: wanted, icons: [], size: 32 }));
        }).then(function(rawIcons) {
          const icons = JSON.parse(rawIcons);
          if (icons.error) throw new Error(icons.error);
          nativeIcons[id] = icons.pages;
          return core.engineCall("ac_history_query", engine, JSON.stringify({ maxUrls: 100, maxVisits: 100 }));
        }).then(function(rawHistory) {
          const nativeHistory = JSON.parse(rawHistory);
          if (nativeHistory.error) throw new Error(nativeHistory.error);
          history[id] = nativeHistory.entries.filter(function(r) { return /^https?:/.test(r.u); }).map(function(r) { return r.u; }).sort();
          return bookmarkSnapshot(id, 0);
        }).then(function(book) {
          if (!book?.ready || !book.hasView) throw new Error("bookmark owner did not become ready");
          const document = JSON.parse(book.document);
          bookmarks[id] = Object.values(document.nodes).filter(function(n) { return n.kind === "url"; }).map(function(n) { return { title: n.title, url: n.url }; }).sort(function(a, b) { return a.url.localeCompare(b.url); });
          cache[id] = Object.fromEntries(Object.entries(ac.favicons.useFavicons.getState().profiles[engine]?.pages ?? {}).filter(function(entry) { return wanted.includes(entry[0]) && entry[1]; }));
        });
      });
    }, Promise.resolve()).then(function() {
      const adoption = JSON.parse(ac.shell.readDocument("sync.json") ?? "null")?.profiles?.default?.themeAdopting ?? false;
      return { profileOrder: s.profileOrder, profiles: s.profiles, windowOrder: s.windowOrder, windows: s.windows, tabs: s.tabs, groups: s.groups, splits: s.splits, parkedPins: s.parkedPins, bookmarks, history, nativeIcons, cache, adoption };
    });
  `);
  const { folders } = await inst.probe("live.snapshot");
  raw.live = folders.map(({ profileId, kind, sources }) => ({ profile: profileId, kind, sources })).sort((a, b) => a.profile.localeCompare(b.profile));
  return canonical(raw);
}

async function acceptance(testCase) {
  const route = "swift";
  const directory = path.join(scratch, testCase.name, route);
  fs.mkdirSync(directory, { recursive: true });
  const sourceFile = path.join(directory, "source.json");
  fs.writeFileSync(sourceFile, JSON.stringify(testCase.source));
  const support = path.join(directory, "source");
  execFileSync("python3", [fileURLToPath(new URL("./sidebar-fixture.py", import.meta.url)), sourceFile, support], { timeout: 10000 });
  const initialSourceHash = sourceHash(support);
  const data = path.join(directory, "data");
  const env = { SOLARA_IMPORT_SOURCE_DIR: support, SOLARA_IMPORT_TEST_SECRET: "fixture-secret", ...testCase.event };
  let inst = await launch(app, { data, probe: true, onboarded: true, env, session: session({ profiles: testCase.initial.profiles, tabs: [{ id: "seed", url: "about:blank", title: "", unloaded: false }, ...(testCase.initial.tabs ?? [])], ...(testCase.initial.session ?? {}), settings: { newTabPosition: "bottom", searchSuggestions: false } }), files: testCase.initial.files });
  let before, outcome, after, repeatOutcome;
  try {
    const drive = (action, argument = null) => inst.eval(`return expo.modules.SolaraSettings.devImport(${JSON.stringify(action)}, ${JSON.stringify(argument)})`);
    const capability = await drive("state");
    assert.equal(typeof capability.pendingWrites, "number", "Debug app required before source discovery");
    await inst.eval('ac.runCommand({ command: "importBrowserData", arg: null, windowId: null }); return true;');
    let state = await bounded(inst, () => drive("state"), (s) => s.step === "choose", "import window");
    assert.equal(typeof state.pendingWrites, "number", "Debug app required");
    assert.ok(state.browsers.includes(testCase.source.browser));
    state = await drive("select", testCase.source.browser);
    assert.deepEqual(state.profileIds, testCase.discovered.profiles);
    assert.deepEqual(state.profileSpaces, testCase.discovered.spaces);
    await drive("kinds", testCase.request.kinds.join(","));
    await drive("profiles", testCase.request.profiles.join(","));
    await drive("spaces", testCase.request.spaces.join(","));
    await drive("target", testCase.request.target);
    if (testCase.initial.cache) await inst.eval(`ac.favicons.adoptFaviconCache("default", ${JSON.stringify(testCase.initial.cache)}); return true;`);
    const run = () => inst.eval(`
      globalThis.__sidebarParityRun = { settled: false };
      Promise.resolve().then(function() {
        return expo.modules.SolaraSettings.devImport("next", null);
      }).then(function(state) {
        if (state.step === "profiles") return expo.modules.SolaraSettings.devImport("next", null);
        return state;
      }).then(function(state) {
        globalThis.__sidebarParityRun = { settled: true, state };
      }).catch(function(error) {
        globalThis.__sidebarParityRun = { settled: true, error: String(error) };
      });
      return true;
    `);
    const finishRun = async () => {
      const result = await bounded(inst, () => inst.eval("return globalThis.__sidebarParityRun"), (s) => s?.settled, "import run");
      if (result.error) throw new Error(result.error);
      return result.state;
    };
    if (testCase.initial.session?.parkedPins) {
      assert.equal(await inst.eval('return ac.store.getState().parkedPins.default?.tabs.length'), 1, "parked duplicate exists before import");
    }
    if (testCase.initial.files?.["sync.json"]?.profiles?.default?.themeAdopting) {
      assert.equal(await inst.eval('return JSON.parse(ac.shell.readDocument("sync.json")).profiles.default.themeAdopting'), true, "adoption metadata is actually persisted before import");
    }
    await run();
    if (testCase.event.SOLARA_IMPORT_TEST_ACK === "holdAdoption") {
      await bounded(inst, () => drive("state"), (s) => s.ackHeld, "handled adoption acknowledgement");
      await drive("cancelRun");
      await drive("ackRelease");
    }
    await finishRun();
    state = await bounded(inst, () => drive("state"), (s) => Object.keys(s.outcome ?? {}).length > 0 && s.pendingWrites === 0, "outcome and writes");
    assert.equal(state.route, "swift");
    outcome = state.outcome;
    fs.writeFileSync(path.join(directory, "outcome.json"), JSON.stringify(state, null, 2));
    before = await snapshot(inst, testCase);
    fs.writeFileSync(path.join(directory, "before.json"), JSON.stringify({ outcome, state: before, facts: facts(before) }, null, 2));
    if (testCase.initial.cache) {
      for (const icon of testCase.initial.cache) assert.equal(before.cache[0][icon.page], `data:image/png;base64,${icon.png}`, "preexisting cache takes precedence");
    }
    compare(outcome, testCase.expected[route].outcome, `${testCase.name}.${route}.outcome`);
    compare(facts(before), testCase.expected[route].state, `${testCase.name}.${route}.state`);
    if (testCase.repeat) {
      await inst.eval('return expo.modules.SolaraSettings.devImport("select", ' + JSON.stringify(testCase.source.browser) + ')');
      await drive("kinds", testCase.request.kinds.join(","));
      await drive("profiles", testCase.request.profiles.join(","));
      await drive("spaces", testCase.request.spaces.join(","));
      await drive("target", testCase.request.target);
      await run();
      await finishRun();
      const repeated = await bounded(inst, () => drive("state"), (s) => Object.keys(s.outcome ?? {}).length > 0 && s.pendingWrites === 0, "repeat");
      repeatOutcome = repeated.outcome;
      compare(repeatOutcome, testCase.expected[route].repeat, "dedupe outcome");
      compare(await snapshot(inst, testCase), before, "dedupe state");
    }
    await inst.quit();
    inst = await launch(app, { data, probe: true, onboarded: true, env });
    after = await snapshot(inst, testCase);
    fs.writeFileSync(path.join(directory, "after.json"), JSON.stringify({ state: after, facts: facts(after) }, null, 2));
    if (testCase.initial.cache) {
      for (const icon of testCase.initial.cache) assert.equal(after.cache[0][icon.page], `data:image/png;base64,${icon.png}`, "cache precedence survives relaunch");
    }
    compare(facts(after), testCase.expected[route].relaunch ?? testCase.expected[route].state, "persisted oracle");
    compare(after.profiles, before.profiles, "persisted profiles and themes");
    compare(after.groups, before.groups, "persisted folder hierarchy");
    compare(after.tabs.filter((t) => !t.url.startsWith("about:blank")), before.tabs.filter((t) => !t.url.startsWith("about:blank")), "persisted tab roles");
    assert.equal(sourceHash(support), initialSourceHash, "source fixtures are unchanged");
    fs.writeFileSync(path.join(directory, "snapshot.json"), JSON.stringify({ outcome, before, after, repeatOutcome, sourceHash: initialSourceHash }, null, 2));
    return { outcome, before, after, ...(repeatOutcome ? { repeatOutcome } : {}) };
  } finally { await inst.quit().catch(() => {}); }
}

let failures = 0;
for (const testCase of cases) {
  const evidence = path.join(scratch, testCase.name);
  fs.mkdirSync(evidence, { recursive: true });
  if (Date.now() - started > 30 * 60 * 1000) {
    failures++;
    fs.writeFileSync(path.join(evidence, "diff.json"), JSON.stringify({ error: "total runtime deadline" }));
    break;
  }
  try {
    await acceptance(testCase);
    fs.writeFileSync(path.join(evidence, "diff.json"), JSON.stringify({ accepted: true }));
    console.log(`ok ${testCase.name}`);
  } catch (error) {
    failures++;
    fs.writeFileSync(path.join(evidence, "diff.json"), JSON.stringify({ message: error.message, actual: error.actual ?? null, expected: error.expected ?? null, stack: error.stack }, null, 2));
    console.error(`FAIL ${testCase.name}: ${error.message}`);
  }
}
process.exitCode = failures ? 1 : 0;

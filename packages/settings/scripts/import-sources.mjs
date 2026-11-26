#!/usr/bin/env node
import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { createHash } from "node:crypto";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { launch, session, sleep, wipeRefusal } from "../../../scripts/lib/instance.mjs";

const [appArg, scratchArg, only] = process.argv.slice(2);
if (!appArg || !scratchArg) throw new Error("usage: import-sources.mjs <Debug.app> <fresh scratch> [case,...]");
const app = fs.realpathSync(appArg), scratch = path.resolve(scratchArg);
if (app.startsWith("/Applications/") || fs.existsSync(scratch)) throw new Error("use an owned Debug app and a new scratch directory");
const refusal = wipeRefusal(scratch);
if (refusal) throw new Error(refusal);
const fixtureRoot = fileURLToPath(new URL("../../import/fixtures/", import.meta.url));
const SECRET = "solara-fixture-secret";
const invalid = "The selected file is invalid. Please try again.";
const counts = (values = {}) => ({ tabs: 0, cookies: 0, addresses: 0, cards: 0, bookmarks: 0, history: 0, passwords: 0, ...values });
const link = (t, u) => ({ t, u });
const folder = (t, c = []) => ({ t, c });
const library = (bar = [], other = [], tabs = [], groups = [], history = []) => ({
  bar: folder("Bookmarks Bar", bar), other: folder("Other Bookmarks", other), tabs: tabs.sort(), groups: groups.sort(), history: history.sort(),
});
const seedTab = ["about:blank", false, "about:blank"];
const workspace = (tabs = [], groups = [], seeded = true) => ({ tabs: [...(seeded ? [seedTab] : []), ...tabs].sort(), groups: groups.sort() });
const started = Date.now();

function hashTree(root) {
  const hash = createHash("sha256");
  function visit(dir) {
    for (const name of fs.readdirSync(dir).sort()) {
      const file = path.join(dir, name);
      if (fs.statSync(file).isDirectory()) visit(file);
      else { hash.update(path.relative(root, file)); hash.update(fs.readFileSync(file)); }
    }
  }
  visit(root);
  return hash.digest("hex");
}

async function bounded(inst, work, predicate, label, milliseconds = 60000) {
  let value;
  for (const end = Date.now() + milliseconds; Date.now() < end; await sleep(100)) {
    if (Date.now() - started > 35 * 60 * 1000) throw new Error("acceptance exceeded thirty-five minutes");
    if (!inst.stillOwned()) throw new Error(`instance exited while waiting for ${label}`);
    value = await work();
    if (predicate(value)) return value;
  }
  throw new Error(`${label} timed out: ${JSON.stringify(value)}`);
}

const tab = (url, title, pinned, windowIndex = 0) => ({ url, title, pinned, windowIndex, active: false });
const fixtures = {
  one: {
    profiles: [{ id: "0:Personal", name: "Personal", index: 0,
      pinned: [tab("https://pinned-one.test/", "Pinned One", true), tab("https://pinned-two.test/", "Pinned Two", true)],
      tabs: [tab("https://open-one.test/", "Open One", false), tab("https://open-two.test/", "Open Two", false), tab("https://open-three.test/", "Open Three", false)] }],
    windowCount: 1, skipped: 0, duplicates: 0, favicons: [],
  },
  two: {
    profiles: [
      { id: "0:Personal", name: "Personal", index: 0, pinned: [tab("https://pinned-one.test/", "Pinned One", true)], tabs: [tab("https://open-one.test/", "Open One", false)] },
      { id: "1:Dia Work", name: "Dia Work", index: 1, pinned: [tab("https://work-pinned.test/", "Work Pinned", true)], tabs: [tab("https://work-open.test/", "Work Open", false), tab("https://work-two.test/", "Work Two", false)] },
    ],
    windowCount: 2, skipped: 0, duplicates: 0, favicons: [],
  },
  empty: { profiles: [], windowCount: 1, skipped: 0, duplicates: 0, favicons: [] },
};

const head = `<!DOCTYPE NETSCAPE-Bookmark-file-1>\n<META HTTP-EQUIV="Content-Type" CONTENT="text/html; charset=UTF-8">\n<TITLE>Bookmarks</TITLE>\n<H1>Bookmarks</H1>\n`;
const files = {
  "nested.html": `${head}<DL><p>
  <DT><H3 ADD_DATE="1700000000" PERSONAL_TOOLBAR_FOLDER="true">Bookmarks bar</H3>
  <DL><p>
    <DT><A HREF="https://bar-one.test/" ADD_DATE="1700000001">Bar one</A>
    <DT><H3>Bar folder</H3>
    <DL><p>
      <DT><A HREF="https://bar-nested.test/a?x=1&amp;y=2">Nested &amp; escaped</A>
      <HR>
      <DT><A HREF="https://bar-nested.test/b">Nested b</A>
    </DL><p>
  </DL><p>
  <DT><A HREF="https://loose.test/">Loose</A>
  <DT><A HREF="https://loose.test/">Loose duplicate</A>
  <DT><H3>Other folder</H3>
  <DL><p>
    <DT><A HREF="https://other.test/">Other</A>
    <DT><A HREF="https://untitled.test/"></A>
    <DT><H3>Empty folder</H3>
    <DL><p>
    </DL><p>
  </DL><p>
</DL><p>
`,
  "second.html": `${head}<DL><p>
  <DT><H3 PERSONAL_TOOLBAR_FOLDER="true">Toolbar</H3>
  <DL><p>
    <DT><A HREF="https://second-bar.test/">Second bar</A>
  </DL><p>
  <DT><A HREF="https://second-other.test/">Second other</A>
</DL><p>
`,
  "nolinks.html": `${head}<DL><p>\n</DL><p>\n`,
  "notes.txt": "just some text, not bookmarks\n",
};

const diaCases = {
  "dia-both": { fixture: "one", kinds: "tabs,pinnedTabs", total: 5, pinned: true, open: true },
  "dia-pinned": { fixture: "one", kinds: "pinnedTabs", total: 2, pinned: true },
  "dia-open": { fixture: "one", kinds: "tabs", total: 3, open: true },
  "dia-two": { fixture: "two", kinds: "tabs,pinnedTabs", total: 5, pinned: true, open: true },
  "dia-empty": { fixture: "empty", kinds: "tabs,pinnedTabs", total: 0 },
};
const safariCases = {
  "safari-zip": { action: "safariExport", file: "Safari Export.zip" },
  "safari-folder": { action: "safariExport", file: "Safari Export" },
  "safari-bad": { action: "safariExport", file: "not-an-export.zip", bad: true },
  "safari-direct": { action: "safariDirect", arg: "cookies" },
  "safari-nocookies": { action: "safariDirect", arg: "nocookies" },
  "safari-locked": { action: "safariDirect", arg: "cookies", locked: true },
};
const chromiumSources = {
  dia: "Dia/User Data", edge: "Microsoft Edge", edgeBeta: "Microsoft Edge Beta", edgeDev: "Microsoft Edge Dev", edgeCanary: "Microsoft Edge Canary",
  brave: "BraveSoftware/Brave-Browser", braveBeta: "BraveSoftware/Brave-Browser-Beta", braveNightly: "BraveSoftware/Brave-Browser-Nightly",
  braveDev: "BraveSoftware/Brave-Browser-Dev", braveOrigin: "BraveSoftware/Brave-Origin", braveOriginBeta: "BraveSoftware/Brave-Origin-Beta",
  braveOriginNightly: "BraveSoftware/Brave-Origin-Nightly", helium: "net.imput.helium", opera: "com.operasoftware.Opera", operaGX: "com.operasoftware.OperaGX",
  vivaldi: "Vivaldi", vivaldiSnapshot: "Vivaldi Snapshot", island: "Island", chromeBeta: "Google/Chrome Beta", chromeDev: "Google/Chrome Dev",
  chromeCanary: "Google/Chrome Canary", chromium: "Chromium",
};
const cases = [
  ...Object.entries(diaCases).map(([name, spec]) => ({ name, type: "dia", ...spec })),
  ...Object.entries(safariCases).map(([name, spec]) => ({ name, type: "safari", ...spec })),
  { name: "html", type: "html" },
  { name: "firefox", type: "firefox" },
  ...Object.entries(chromiumSources).map(([browser, source]) => ({ name: `chromium-${browser}`, type: "chromium", browser, source })),
];
const wanted = only?.split(",");
if (wanted?.some((name) => !cases.some((entry) => entry.name === name))) throw new Error("unknown acceptance case");
fs.mkdirSync(scratch, { recursive: true });

function prepare(spec, directory) {
  const home = path.join(directory, "home");
  const support = path.join(home, "Library/Application Support");
  const diaFixture = path.join(directory, "dia.json");
  fs.mkdirSync(support, { recursive: true });
  fs.writeFileSync(diaFixture, JSON.stringify(spec.type === "dia" ? fixtures[spec.fixture] : fixtures.empty));
  const env = {
    SOLARA_IMPORT_SOURCE_DIR: support,
    SOLARA_IMPORT_SAFARI_HOME: home,
    SOLARA_IMPORT_TEST_SECRET: SECRET,
    SOLARA_IMPORT_DIA_FIXTURE: diaFixture,
    SOLARA_IMPORT_DIA_BUNDLE_ID: "invalid.solara.acceptance.no-dia",
  };
  if (spec.type === "safari" || spec.type === "firefox") {
    fs.cpSync(path.join(fixtureRoot, "home"), home, { recursive: true });
    execFileSync("python3", ["-I", fileURLToPath(new URL("../../import/scripts/shift-fixture-history.py", import.meta.url)), home], { timeout: 15000 });
  }
  if (spec.type === "safari") {
    fs.cpSync(path.join(fixtureRoot, "safari"), path.join(directory, "exports"), { recursive: true });
    if (spec.locked) {
      for (const name of ["Bookmarks.plist", "History.db"]) fs.chmodSync(path.join(home, "Library/Safari", name), 0o000);
    }
  }
  if (spec.type === "html") {
    for (const [name, body] of Object.entries(files)) fs.writeFileSync(path.join(directory, name), body);
  }
  if (spec.type === "chromium") {
    const root = path.join(support, spec.source);
    const rootIsProfile = spec.browser === "opera" || spec.browser === "operaGX";
    const profile = rootIsProfile ? root : path.join(root, "Default");
    fs.mkdirSync(profile, { recursive: true });
    fs.writeFileSync(path.join(root, "Local State"), JSON.stringify({ profile: { info_cache: rootIsProfile ? {} : { Default: { name: "Fixture" } } } }));
    fs.writeFileSync(path.join(profile, "Preferences"), "{}");
    const bookmark = { type: "url", name: spec.browser, url: `https://${spec.browser.toLowerCase()}.fixture.test/` };
    fs.writeFileSync(path.join(profile, "Bookmarks"), JSON.stringify({ version: 1, roots: {
      bookmark_bar: { type: "folder", name: "Bookmarks bar", children: [bookmark] },
      other: { type: "folder", name: "Other bookmarks", children: [] },
      synced: { type: "folder", name: "Mobile bookmarks", children: [] },
    } }));
  }
  for (const key of ["SOLARA_IMPORT_SOURCE_DIR", "SOLARA_IMPORT_SAFARI_HOME", "SOLARA_IMPORT_DIA_FIXTURE"]) {
    const real = fs.realpathSync(env[key]);
    assert.ok(real.startsWith(fs.realpathSync(directory) + path.sep), `${key} stays in owned fixtures`);
  }
  return env;
}

async function snapshot(inst) {
  return inst.eval(`
    const s = ac.store.getState();
    const b = s.bookmarks ?? { nodes: {}, roots: {} };
    const walk = (id) => { const n = b.nodes[id]; if (!n) return null; return n.kind === "folder" ? { t: n.title, c: (n.children ?? []).map(walk) } : { t: n.title, u: n.url }; };
    const r = b.roots.default;
    const workspace = {};
    for (const id of s.profileOrder) {
      workspace[s.profiles[id].name] = {
        tabs: Object.values(s.tabs).filter((t) => t.profileId === id).map((t) => [t.url ?? t.navigation?.url ?? "", !!t.pinned, t.title ?? ""]).sort(),
        groups: Object.values(s.groups ?? {}).filter((g) => g.profileId === id).map((g) => [g.name ?? "", (g.tabIds ?? []).length]).sort()
      };
    }
    return { workspace, profiles: s.profileOrder.map((id) => s.profiles[id].name), library: {
      bar: r ? walk(r.bar) : null, other: r ? walk(r.other) : null,
      tabs: workspace.Personal.tabs.map((t) => t.slice(0, 2)).sort(), groups: workspace.Personal.groups,
      history: (s.history.default ?? []).map((h) => h.url + " " + h.visits).sort()
    } };
  `);
}

function diaExpected(spec) {
  const profiles = fixtures[spec.fixture].profiles;
  const expected = { Personal: workspace() };
  for (const [index, profile] of profiles.entries()) {
    const tabs = [...(spec.pinned ? profile.pinned : []), ...(spec.open ? profile.tabs : [])].map((t) => [t.url, t.pinned, t.title]);
    expected[index ? profile.name : "Personal"] = workspace(tabs, spec.open ? [["Imported", profile.tabs.length]] : [], index === 0);
  }
  return expected;
}

const safariExportLibrary = library([], [
  link("Apple", "https://www.apple.example/"), link("News & Views", "https://news.example/?a=1&b=2"),
  folder("Japan", [link("京都 guide", "https://kyoto.example/")]), folder("Reading List", [link("A long read", "https://longread.example/article")]),
], [["about:blank", false]], [], ["https://newest.safari.example/ 9", "https://www.apple.example/maps/ 3"]);
const safariDirectLibrary = library([
  link("Apple", "https://apple.example/"), folder("Travel", [link("京都 guide", "https://kyoto.example/")]),
], [folder("Reading List", [link("A long read", "https://longread.example/article")])],
[["about:blank", false], ["https://apple.example/", false], ["https://news.example/", false]], [["Imported", 2]], ["https://apple.example/ 3", "https://news.example/ 5"]);
const htmlLibrary = library([
  link("Bar one", "https://bar-one.test/"), folder("Bar folder", [link("Nested & escaped", "https://bar-nested.test/a?x=1&y=2"), link("Nested b", "https://bar-nested.test/b")]),
  folder("Imported from HTML File", [link("Second bar", "https://second-bar.test/")]),
], [
  link("Loose", "https://loose.test/"), link("Loose duplicate", "https://loose.test/"), link("Other", "https://other.test/"), link("https://untitled.test/", "https://untitled.test/"), folder("Empty folder"),
  folder("Imported from HTML File", [link("Second other", "https://second-other.test/")]),
], [["about:blank", false]]);
const firefoxLibrary = library([
  link("Mozilla", "https://www.mozilla.example/"), folder("Dev & Docs", [link("MDN", "https://developer.mozilla.example/docs")]),
], [folder("Bookmarks Menu", [link("Never visited", "https://bookmarked-never-visited.example/")]), link("WAL bookmark", "https://in-wal.example/")],
[["about:blank", false], ["https://www.mozilla.example/", true], ["https://a.example/", false], ["https://second.example/", false]],
[["Imported", 2]], ["https://developer.mozilla.example/docs 4", "https://in-wal.example/ 1", "https://tagged.example/ 1", "https://www.mozilla.example/ 10"]);

async function acceptance(spec) {
  if (Date.now() - started > 35 * 60 * 1000) throw new Error("acceptance exceeded thirty-five minutes");
  const directory = path.join(scratch, spec.name);
  fs.mkdirSync(directory);
  const env = prepare(spec, directory);
  const sourceHash = hashTree(env.SOLARA_IMPORT_SOURCE_DIR);
  const inst = await launch(app, { data: path.join(directory, "data"), probe: true, onboarded: true, keepData: true, env,
    session: session({ profiles: ["Personal"], tabs: [{ id: "seed", url: "about:blank", title: "", unloaded: false }], settings: { searchSuggestions: false } }),
  });
  const evidence = { name: spec.name };
  try {
    const drive = (action, arg = null) => inst.eval(`return expo.modules.SolaraSettings.devImport(${JSON.stringify(action)}, ${JSON.stringify(arg)})`);
    assert.equal(typeof (await drive("state")).pendingWrites, "number", "Debug app required before source discovery");
    await inst.eval('ac.runCommand({ command: "importBrowserData", arg: null, windowId: null }); return true;');
    await bounded(inst, () => drive("state"), (s) => s.step === "choose", "import window", 30000);
    await bounded(inst, () => snapshot(inst), (s) => s.library.bar !== null && s.library.other !== null, "initial bookmark roots", 15000);
    await drive("traceReset");
    await drive("target", "default");
    let state;
    if (spec.type === "dia") {
      assert.ok((await drive("state")).browsers.includes("diaTabs"), "Dia reference bundle discovered");
      await drive("select", "diaTabs");
      await drive("kinds", spec.kinds);
      state = await drive("next");
      if (state.step === "profiles") {
        await drive("profiles", "0:Personal,1:Dia Work");
        state = await drive("next");
      }
    } else if (spec.type === "safari") {
      const arg = spec.file ? path.join(directory, "exports", spec.file) : spec.arg;
      state = await drive(spec.action, arg);
    } else if (spec.type === "html") {
      evidence.steps = [];
      for (const file of ["nested.html", "second.html", "nolinks.html", "notes.txt"]) {
        state = await drive("html", path.join(directory, file));
        evidence.steps.push({ file, step: state.step, bookmarks: state.counts.bookmarks, error: state.error ?? null, failures: state.failures });
      }
    } else {
      const browser = spec.type === "firefox" ? "firefox" : spec.browser;
      assert.ok((await drive("state")).browsers.includes(browser), `${browser} fixture discovered`);
      state = await drive("select", browser);
      await drive("kinds", spec.type === "firefox" ? "bookmarks,history,tabs" : "bookmarks");
      if (spec.type === "firefox") {
        const profile = state.profileIds.find((id) => id.endsWith("abcd1234.default-release"));
        assert.ok(profile, "Firefox default release profile discovered");
        await drive("profiles", profile);
      }
      state = await drive("next");
      if (state.step === "profiles") state = await drive("next");
    }
    state = await bounded(inst, () => drive("state"), (s) => s.step !== "progress" && s.pendingWrites === 0, "import and pending writes");
    evidence.state = state;
    evidence.snapshot = await snapshot(inst);
    const log = inst.output();
    evidence.routes = [...log.matchAll(/\[import\] (?:file (\w+)|run \S+) route=(\w+)/g)].map((m) => [m[1] ?? "run", m[2]]);
    assert.ok(!/LogBox|Unhandled JS Exception|RedBox/i.test(log) && !inst.jsErrors(), "no JS errors");
    assert.ok(!/Dia isn't running|AEDeterminePermission|openApplication/.test(log), "never reached real Dia");
    assert.ok(!/route=js|reason=defaults/.test(log), "no script routing");
    assert.deepEqual(state.failures, [], "no import failures");
    assert.equal(state.vault, 0, "vault empty after import");
    assert.equal(hashTree(env.SOLARA_IMPORT_SOURCE_DIR), sourceHash, "source profiles unchanged");
    const verifySnapshot = async (expected) => {
      await bounded(inst, async () => {
        evidence.snapshot = await snapshot(inst);
        return evidence.snapshot;
      }, (s) => {
        try { for (const [key, value] of Object.entries(expected)) assert.deepEqual(s[key], value); return true; } catch { return false; }
      }, "exact workspace and library", 15000);
      for (const [key, value] of Object.entries(expected)) assert.deepEqual(evidence.snapshot[key], value, key);
    };
    if (spec.type === "dia") {
      assert.deepEqual(state.counts, counts({ tabs: spec.total }));
      assert.deepEqual(state.notes, []);
      assert.equal(state.step, spec.fixture === "empty" ? "dia" : "done");
      assert.equal(state.error ?? null, spec.fixture === "empty" ? "Dia has no open or pinned web pages to import." : null);
      assert.deepEqual(state.trace, fixtures[spec.fixture].profiles.flatMap(() => ["favicons", "workspace"]), "Swift Dia runner trace per selected profile");
      await verifySnapshot({ workspace: diaExpected(spec) });
    } else if (spec.type === "safari") {
      assert.deepEqual(evidence.routes, [[spec.action, "swift"]]);
      assert.deepEqual([SECRET, "hunter2", "4111111111111111", "correct horse"].filter((value) => log.includes(value)), [], "no fixture secrets in logs");
      const failed = spec.bad || spec.locked;
      assert.equal(state.step, failed ? "safari" : "done");
      const appName = execFileSync("/usr/libexec/PlistBuddy", ["-c", "Print :CFBundleName", path.join(app, "Contents/Info.plist")], { encoding: "utf8", timeout: 10000 }).trim();
      assert.equal(state.error ?? null, spec.bad ? invalid : spec.locked ? `${appName} still doesn't have Full Disk Access. Grant it above, or use the export file below.` : null);
      const exporting = spec.action === "safariExport";
      assert.deepEqual(state.counts, failed ? counts() : exporting ? counts({ bookmarks: 4, history: 2, passwords: 2, cards: 2 }) : counts({ bookmarks: 3, history: 2, tabs: 2, cookies: spec.arg === "cookies" ? 3 : 0 }));
      if (failed) {
        await verifySnapshot({ profiles: ["Personal"], library: library([], [], [["about:blank", false]]) });
      } else await verifySnapshot({ profiles: ["Personal"], library: exporting ? safariExportLibrary : safariDirectLibrary });
    } else if (spec.type === "html") {
      assert.deepEqual(evidence.routes, Array.from({ length: 4 }, () => ["bookmarksHTML", "swift"]));
      assert.deepEqual(evidence.steps, [
        { file: "nested.html", step: "done", bookmarks: 7, error: null, failures: [] },
        { file: "second.html", step: "done", bookmarks: 2, error: null, failures: [] },
        { file: "nolinks.html", step: "done", bookmarks: 2, error: invalid, failures: [] },
        { file: "notes.txt", step: "done", bookmarks: 2, error: invalid, failures: [] },
      ]);
      await verifySnapshot({ library: htmlLibrary });
    } else {
      assert.equal(state.step, "done");
      assert.equal(state.error ?? null, null);
      assert.equal(state.route, "swift");
      assert.deepEqual(evidence.routes, [["run", "swift"]]);
      if (spec.type === "firefox") {
        assert.deepEqual(state.counts, counts({ bookmarks: 4, history: 4, tabs: 3 }));
        await verifySnapshot({ profiles: ["Personal"], library: firefoxLibrary });
      } else {
        assert.deepEqual(state.counts, counts({ bookmarks: 1 }));
        await verifySnapshot({ profiles: ["Personal"], library: library([link(spec.browser, `https://${spec.browser.toLowerCase()}.fixture.test/`)], [], [["about:blank", false]]) });
      }
    }
  } finally {
    try {
      fs.writeFileSync(path.join(directory, "result.json"), JSON.stringify(evidence, null, 2));
    } finally {
      await inst.quit().catch(() => {});
      if (spec.locked) for (const name of ["Bookmarks.plist", "History.db"]) fs.chmodSync(path.join(env.SOLARA_IMPORT_SAFARI_HOME, "Library/Safari", name), 0o600);
    }
  }
}

const results = [];
for (const spec of cases.filter((entry) => !wanted || wanted.includes(entry.name))) {
  try {
    await acceptance(spec);
    results.push({ name: spec.name, accepted: true });
    console.log(`ok ${spec.name}`);
  } catch (error) {
    results.push({ name: spec.name, accepted: false, message: error.message, actual: error.actual ?? null, expected: error.expected ?? null, stack: error.stack });
    console.error(`FAIL ${spec.name}: ${error.message}`);
  }
  fs.writeFileSync(path.join(scratch, "result.json"), JSON.stringify(results, null, 2));
}
process.exitCode = results.length && results.every((result) => result.accepted) ? 0 : 1;

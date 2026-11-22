import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { createRequire } from "node:module";
import { test } from "node:test";
import { runInNewContext } from "node:vm";

const ts = createRequire(import.meta.url)("typescript");
const emptyCounts = () => ({ bookmarks: 0, history: 0, passwords: 0, cookies: 0, addresses: 0, cards: 0, tabs: 0 });

function handlerFixture(options = {}) {
  const profiles = [{ id: "first", name: "First" }, { id: "second", name: "Second" }];
  const applied = [];
  let forgotten = 0;
  const browser = { id: "chrome", name: "Chrome", family: "chromium", profiles };
  const api = {
    listBrowsers: async () => [browser],
    importData: async (_, id) => {
      await options.read?.();
      return { profile: profiles.find((p) => p.id === id), failed: [], warnings: [], spaces: [] };
    },
    listExtensions: async () => [],
    forgetUnlockedKeys: () => forgotten++,
    readDiaTabs: async () => ({ profiles: profiles.map((p) => ({ ...p, pinned: [], tabs: [] })), windowCount: 1, favicons: {} }),
  };
  const imports = {
    "@solara/shell": {},
    "@solara/settings": { publishSettingsTopic: () => {} },
    "../../../lib/bookmarkGroups": {},
    "../../../lib/bookmarkWriter": { reportBookmarkFailure: () => {} },
    "../../../lib/favicons": { adoptFaviconCache: () => null },
    "../../../store/nativeStore": { nativeSafeMode: () => false },
    "../../../store/browser": { useBrowser: { getState: () => options.state ?? ({ profileOrder: [], profiles: {}, ui: {}, windows: {}, settings: { defaultProfileId: "existing" }, createProfile: () => { throw new Error("Profile data is deleted"); } }) } },
    "../../../store/draftGroups": {},
    "../../../store/model": {},
    "../../onboarding/state": {},
    "../../import/apply": {
      emptyCounts,
      profileColorFor: () => undefined,
      transientImportRefused: () => false,
      applyResult: async (dest) => { await options.apply?.(); applied.push(dest); return { ...emptyCounts(), bookmarks: 3 }; },
      importDiaProfile: (dest) => { applied.push(dest); return 4; },
    },
    "../../import/module": { importModule: () => api },
    "../windows": { takePreferredImportSource: () => null },
  };
  const module = { exports: {} };
  const source = readFileSync(new URL("./import.ts", import.meta.url), "utf8");
  runInNewContext(ts.transpileModule(source, { compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2022 } }).outputText, {
    exports: module.exports,
    require: (name) => { if (name in imports) return imports[name]; throw new Error(`Unexpected import: ${name}`); },
    AbortController,
  });
  return { handlers: module.exports.importHandlers, applied, forgotten: () => forgotten };
}

test("adopting history from Swift reports how much the profile's list grew, as the JS import does", () => {
  const state = {
    history: { p: Array.from({ length: 4990 }, (_, i) => ({ url: `https://old${i}.test/` })) },
    adoptImportedHistory(profileId, rows) {
      state.history = { ...state.history, [profileId]: [...rows.map((r) => ({ url: r.url })), ...(state.history[profileId] ?? [])].slice(0, 5000) };
      return rows.length;
    },
  };
  const fixture = handlerFixture({ state });
  const rows = Array.from({ length: 50 }, (_, i) => ({ url: `https://new${i}.test/`, title: "", visits: 1, lastVisit: Date.now() }));
  assert.equal(fixture.handlers["import.adoptHistory"]("p", rows), 10);
  assert.equal(fixture.handlers["import.adoptHistory"]("q", "not rows"), 0);
});

test("real import handler returns failed status and partial counts when the second destination is refused", async () => {
  const fixture = handlerFixture();
  await fixture.handlers["import.listBrowsers"]();
  const result = await fixture.handlers["import.run"]({ runId: "run", browserId: "chrome", profileIds: ["first", "second"], spaceIds: [], kinds: ["bookmarks"], target: "existing", withoutKey: false });
  assert.equal(result.cancelled, undefined);
  assert.equal(result.status.bookmarks, "failed");
  assert.equal(result.counts.bookmarks, 3);
  assert.deepEqual(Array.from(result.failures[0].profiles), ["Second"]);
  assert.deepEqual(fixture.applied, ["existing"]);
  assert.equal(fixture.forgotten(), 1);
});

test("real Dia handler returns failed status and partial counts when the second destination is refused", async () => {
  const fixture = handlerFixture();
  await fixture.handlers["import.readDia"]();
  const result = await fixture.handlers["import.runDia"]({ profileIds: ["first", "second"], target: "existing", pinned: true, open: true });
  assert.equal(result.status.tabs, "failed");
  assert.equal(result.status.pinnedTabs, "failed");
  assert.equal(result.counts.tabs, 4);
  assert.deepEqual(Array.from(result.failures[0].profiles), ["Second"]);
  assert.deepEqual(fixture.applied, ["existing"]);
});

function deferred() {
  let resolve;
  const promise = new Promise((done) => { resolve = done; });
  return { promise, resolve };
}

for (const phase of ["read", "apply"]) {
  test(`sync cancellation drains a pending import ${phase} before joining`, async () => {
    const entered = deferred();
    const release = deferred();
    const fixture = handlerFixture({ [phase]: async () => { entered.resolve(); await release.promise; } });
    await fixture.handlers["import.listBrowsers"]();
    const run = fixture.handlers["import.run"]({ runId: "run", browserId: "chrome", profileIds: ["first"], spaceIds: [], kinds: ["bookmarks"], target: "existing", withoutKey: false });
    await entered.promise;
    let drained = false;
    const drain = Promise.resolve((fixture.handlers["import.cancelAndDrain"] ?? fixture.handlers["import.cancel"])()).then(() => { drained = true; });
    await new Promise((done) => setImmediate(done));
    assert.equal(drained, false);
    release.resolve();
    await run;
    await drain;
    assert.equal(drained, true);
    assert.deepEqual(fixture.applied, phase === "read" ? [] : ["existing"]);
    const count = fixture.applied.length;
    await fixture.handlers["import.run"]({ runId: "late", browserId: "chrome", profileIds: ["first"], spaceIds: [], kinds: ["bookmarks"], target: "joined", withoutKey: false });
    assert.equal(fixture.applied.length, count);
  });
}

test("an import window opening during sync cancellation cannot bypass the drain", async () => {
  const entered = deferred();
  const release = deferred();
  let reads = 0;
  const fixture = handlerFixture({ read: async () => { if (++reads === 1) { entered.resolve(); await release.promise; } } });
  await fixture.handlers["import.listBrowsers"]();
  const request = (target) => ({ runId: target, browserId: "chrome", profileIds: ["first"], spaceIds: [], kinds: ["bookmarks"], target, withoutKey: false });
  const run = fixture.handlers["import.run"](request("existing"));
  await entered.promise;
  const drain = fixture.handlers["import.cancelAndDrain"]();
  await fixture.handlers["import.open"]();
  await fixture.handlers["import.run"](request("joined"));
  release.resolve();
  await run;
  await drain;
  assert.deepEqual(fixture.applied, []);
});

const adoptedBrowsers = JSON.stringify([{ id: "chrome", name: "Chrome", family: "chromium", profiles: [{ id: "first", name: "First" }, { id: "second", name: "Second" }] }]);

test("adopting the browser list from Swift prepares a run exactly like listing in JS", async () => {
  const listed = handlerFixture();
  await listed.handlers["import.listBrowsers"]();
  const adopted = handlerFixture();
  assert.equal(adopted.handlers["import.adoptBrowsers"](adoptedBrowsers), true);
  const request = { runId: "run", browserId: "chrome", profileIds: ["first", "second"], spaceIds: [], kinds: ["bookmarks"], target: "existing", withoutKey: false };
  const a = await listed.handlers["import.run"](request);
  const b = await adopted.handlers["import.run"](request);
  assert.deepEqual(JSON.parse(JSON.stringify(b)), JSON.parse(JSON.stringify(a)));
  assert.deepEqual(adopted.applied, listed.applied);
});

test("a run with no adopted or listed browsers is cancelled, as before", async () => {
  const fixture = handlerFixture();
  const result = await fixture.handlers["import.run"]({ runId: "run", browserId: "chrome", profileIds: ["first"], spaceIds: [], kinds: ["bookmarks"], target: "existing", withoutKey: false });
  assert.equal(result.cancelled, true);
});

test("regression guard, true before C2 as well: a run keeps the source it started with when the browser list is replaced mid-run", async () => {
  const entered = deferred();
  const release = deferred();
  const fixture = handlerFixture({ read: async () => { entered.resolve(); await release.promise; } });
  fixture.handlers["import.adoptBrowsers"](adoptedBrowsers);
  const run = fixture.handlers["import.run"]({ runId: "run", browserId: "chrome", profileIds: ["first"], spaceIds: [], kinds: ["bookmarks"], target: "existing", withoutKey: false });
  await entered.promise;
  fixture.handlers["import.adoptBrowsers"]("[]");
  release.resolve();
  const result = await run;
  assert.equal(result.cancelled, undefined);
  assert.equal(result.status.bookmarks, "done");
  assert.deepEqual(fixture.applied, ["existing"]);
});

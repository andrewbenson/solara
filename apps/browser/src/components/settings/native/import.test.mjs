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
    "../../../store/nativeStore": { nativeSafeMode: () => false },
    "../../../store/browser": { useBrowser: { getState: () => ({ profileOrder: [], profiles: {}, ui: {}, windows: {}, settings: { defaultProfileId: "existing" }, createProfile: () => { throw new Error("Profile data is deleted"); } }) } },
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

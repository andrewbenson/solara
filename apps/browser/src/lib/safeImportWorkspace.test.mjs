import assert from "node:assert/strict";
import { createRequire } from "node:module";
import { test } from "node:test";
import { source } from "../test-native/safe-host/run.mjs";

const ts = createRequire(import.meta.url)("typescript");
const emptyCounts = () => ({ bookmarks: 0, history: 0, tabs: 0, passwords: 0, cookies: 0, addresses: 0, cards: 0 });

function load(path, modules) {
  const output = ts.transpileModule(source(path), { compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2022 } }).outputText;
  const api = {};
  new Function("require", "exports", output)((name) => modules[name] ?? {}, api);
  return api;
}

function harness(safe, profiles = 1) {
  const messages = [];
  const effects = [];
  const state = { profiles: { existing: { id: "existing", name: "Existing" } }, profileOrder: ["existing"],
    createProfile: (arg) => { effects.push(["profile", arg]); return "new-profile"; } };
  const api = {
    listBrowsers: async () => [{ id: "fixture", name: "Fixture", family: "chromium", profiles: Array.from({ length: profiles }, (_, i) => ({ id: `source-${i}`, name: `Source ${i}` })) }],
    importData: async (browser, profile, kinds) => { effects.push(["read", profile, kinds]); return { tabs: [], spaces: [], favorites: [], credentials: [], failed: [], warnings: [] }; },
    listExtensions: async () => [], forgetUnlockedKeys() {},
    readDiaTabs: async () => ({ windowCount: 1, profiles: [{ id: "dia", name: "Dia", tabs: [{}], pinned: [] }] }),
  };
  const handlers = load("apps/browser/src/components/settings/native/import.ts", {
    "@solara/shell": { confirm: async (options) => { messages.push(options); return { confirmed: true }; } },
    "@solara/settings": { publishSettingsTopic() {} },
    "../../../store/nativeStore": { nativeSafeMode: () => safe },
    "../../../store/browser": { useBrowser: { getState: () => state } },
    "../../../store/model": { plural: (n, word) => `${n} ${word}` },
    "../../import/module": { importModule: () => api },
    "../../import/apply": { emptyCounts, profileColorFor: () => undefined,
      transientImportRefused: () => { if (!safe) return false; messages.push({ message: "Open Solara normally to save imported workspaces" }); return true; },
      applyResult: async (target, value, name, kinds) => { effects.push(["apply", target, kinds]); return emptyCounts(); },
      importDiaProfile: () => { effects.push(["dia"]); return 1; } },
  }).importHandlers;
  const request = (kinds) => ({ runId: "run", browserId: "fixture", profileIds: Array.from({ length: profiles }, (_, i) => `source-${i}`), spaceIds: [], kinds, target: "existing", withoutKey: false });
  return { handlers, effects, messages, request };
}

for (const safe of [true, false]) {
  test(`workspace import reports refused kinds while durable kinds proceed in mode ${safe}`, async () => {
    const h = harness(safe);
    await h.handlers["import.listBrowsers"]();
    const out = await h.handlers["import.run"](h.request(["bookmarks", "tabs", "favorites"]));
    assert.equal(out.status.bookmarks, "done");
    for (const kind of ["tabs", "favorites"]) assert.equal(out.status[kind], safe ? "failed" : "done");
    assert.deepEqual(h.effects.find(([op]) => op === "apply")[2], safe ? ["bookmarks"] : ["bookmarks", "tabs", "favorites"]);
    assert.equal(h.messages.length, safe ? 1 : 0);
    if (safe) assert.match(h.messages[0].message, /normal|normally/i);
  });

  test(`multi-profile imports avoid false success for ephemeral new profiles in mode ${safe}`, async () => {
    const h = harness(safe, 2);
    await h.handlers["import.listBrowsers"]();
    const out = await h.handlers["import.run"](h.request(["passwords"]));
    assert.equal(out.status.passwords, safe ? "failed" : "done");
    assert.equal(h.effects.filter(([op]) => op === "profile").length, safe ? 0 : 1);
    assert.equal(h.effects.filter(([op]) => op === "apply").length, safe ? 0 : 2);
    assert.equal(h.messages.length, safe ? 1 : 0);
  });

  test(`Dia import has a visible refusal before workspace effects in mode ${safe}`, async () => {
    const h = harness(safe);
    await h.handlers["import.readDia"]();
    const out = await h.handlers["import.runDia"]({ profileIds: ["dia"], target: "existing", pinned: false, open: true });
    assert.equal(out.counts.tabs, safe ? 0 : 1);
    assert.equal(h.effects.filter(([op]) => op === "dia").length, safe ? 0 : 1);
    assert.equal(h.messages.length, safe ? 1 : 0);
  });
}

function applyHarness(safe, native = false) {
  const messages = [];
  const writes = [];
  const state = { history: {}, importHistory() {}, createGroup() {}, tabs: {}, windows: { window: { incognito: false, tabIds: [] } }, windowOrder: ["window"], ui: { focusOrder: [] }, groups: {}, profiles: { existing: {} } };
  const api = load("apps/browser/src/components/import/apply.ts", {
    "@solara/shell": { confirm: async (options) => { messages.push(options); return { confirmed: true }; } },
    "@solara/store": { encodeCommand: (op, args) => ({ op, args }) },
    "../../store/nativeStore": { nativeSafeMode: () => safe, nativeOwnsWorkspace: () => native, nativeWrite: (command) => { writes.push(command); return { result: { tabs: command.args[0].windows.reduce((n, w) => n + w.tabs.length, 0), skipped: 0 } }; }, writeState: (store, next) => { writes.push("workspace"); Object.assign(state, next); } },
    "../../store/browser": { useBrowser: { getState: () => state } },
    "../../store/pageKeys": { openPages: () => new Set(), pinnedPages: () => new Set(), tilePages: () => new Set(), pageKey: (url) => url },
    "../../store/model": { engineProfile: (id) => id, isIncognitoProfile: () => false },
    "../../store/tabs": { withNewTab: (s, windowId, args) => [{ ...s, tabs: { ...s.tabs, fixture: args } }, "fixture"] },
    "../../lib/bookmarkGroups": { addGroupsFromDrafts: () => ({ made: [], skipped: 0 }) },
    "./module": { importModule: () => null },
  });
  return { api, state, writes, messages };
}

for (const safe of [true, false]) {
  test(`direct tabs, Arc and Dia helpers preserve durable state in mode ${safe}`, () => {
    for (const kind of ["tabs", "arc", "dia"]) {
      const h = applyHarness(safe);
      const tab = { url: "https://fixture.test/", title: "Fixture" };
      const out = kind === "tabs" ? h.api.importTabs("existing", [tab], null)
        : kind === "dia" ? h.api.importDiaProfile("existing", { tabs: [tab], pinned: [] }, { pinned: false, open: true })
          : h.api.importArcSpace("existing", { tabs: [tab], pinned: [] }).tabs;
      assert.equal(out, safe ? 0 : 1);
      assert.equal(h.writes.includes("workspace"), !safe);
      assert.equal(h.messages.length, safe ? 1 : 0);
      if (safe) assert.deepEqual(h.state.tabs, {});
    }
  });

  test(`Safari import reports refused tabs without false counts in mode ${safe}`, async () => {
    const h = applyHarness(safe);
    const failed = [];
    const out = await h.api.applySafari("existing", { profiles: [], tabs: [{ url: "https://fixture.test/", title: "Fixture" }], credentials: [] }, false, (kind) => failed.push(kind));
    assert.equal(out.tabs, safe ? 0 : 1);
    assert.deepEqual(failed, safe ? ["tabs"] : []);
    assert.equal(h.messages.length, safe ? 1 : 0);
  });
}

for (const native of [false, true]) {
  for (const safe of [true, false]) {
    test(`direct import helpers route through workspace ownership ${native} in mode ${safe}`, () => {
      for (const kind of ["tabs", "arc", "dia"]) {
        const h = applyHarness(safe, native);
        const tab = { url: "https://fixture.test/", title: "Fixture" };
        const out = kind === "tabs" ? h.api.importTabs("existing", [tab], null)
          : kind === "dia" ? h.api.importDiaProfile("existing", { tabs: [tab], pinned: [] }, { pinned: false, open: true })
            : h.api.importArcSpace("existing", { tabs: [tab], pinned: [] }).tabs;
        assert.equal(out, safe ? 0 : 1);
        assert.equal(h.writes.length, safe ? 0 : 1);
        if (!safe && native) assert.equal(h.writes[0].op, "importWorkspace");
        assert.equal(h.messages.length, safe ? 1 : 0);
      }
    });

    test(`combined import visibly refuses workspace kinds under ownership ${native} in mode ${safe}`, async () => {
      const h = applyHarness(safe, native);
      const failed = [];
      const tab = { url: "https://fixture.test/", title: "Fixture" };
      const out = await h.api.applyResult("existing", { tabs: [tab], favorites: [{ ...tab, pinned: true }], spaces: [], history: [], credentials: [] }, "Fixture", ["tabs", "favorites"], (kind) => failed.push(kind));
      assert.equal(out.tabs, safe ? 0 : 2);
      assert.equal(h.writes.length, safe ? 0 : native ? 1 : 2);
      assert.deepEqual(failed, safe ? ["tabs", "favorites"] : []);
      assert.equal(h.messages.length, safe ? 1 : 0);
      if (!safe && native) assert.equal(h.writes[0].op, "importWorkspace");
    });
  }
}

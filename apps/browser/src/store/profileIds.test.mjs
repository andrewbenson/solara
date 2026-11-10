import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { createRequire } from "node:module";
import { test } from "node:test";
import { runInNewContext } from "node:vm";
import { declaration, runNative, source } from "../test-native/safe-host/run.mjs";

const ts = createRequire(import.meta.url)("typescript");
const bookmarkProjection = await import("./bookmarkProjection.ts");
const compile = (text) => ts.transpileModule(text, { compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2022 } }).outputText;
const load = (path, imports) => {
  const module = { exports: {} };
  runInNewContext(compile(readFileSync(new URL(path, import.meta.url), "utf8")), { exports: module.exports, require: (name) => {
    assert.ok(name in imports, `Unexpected import ${name}`);
    return imports[name];
  }, console, Date, Math });
  return module.exports;
};
const accepted = ["default", "p-mgg8w000-1", "p-mgg8w000abcd-z", "p-01234567-89ab-cdef-0123-456789abcdef-1"];
const refused = ["P-mgg8w000-1", "p-mgg8W000-1", "p-01234567-89AB-cdef-0123-456789abcdef-1", "off-shape", "p-launch-01", "p-launch-1\n", "default\n", "p-a-0"];

function profiles(generated = accepted[1]) {
  const api = load("./profiles.ts", {
    "./bookmarkProjection": bookmarkProjection,
    "@solara/shell": { confirm() {} },
    "./bookmarks": { ensureRoots: (bookmarks) => [bookmarks, {}] },
    "./model": { newId: () => generated },
    "./settings": { DEFAULT_PROFILE_ID: "default" },
    "./nativeStore": { nativeSafeMode: () => false },
    "./tabs": {},
  });
  let state = {};
  const set = (patch) => { state = { ...state, ...(typeof patch === "function" ? patch(state) : patch) }; };
  const slice = api.createProfilesSlice(set, () => state, { subscribe() {} });
  state = { ...slice, bookmarks: {}, history: {} };
  return { ...api, state: () => state };
}

test("all historical generated shapes are accepted exactly in JS and native syntax", () => {
  const api = profiles();
  for (const id of accepted) assert.equal(api.validProfileId(id), true, id);
  for (const id of refused) assert.equal(api.validProfileId(id), false, id);
  const native = declaration(source("native/SolaraKit/Sources/SolaraStore/ProfileDataCleanup.swift"), "nonisolated static func validProfileId(");
  assert.deepEqual(runNative("ProfileIds.swift", native, [...accepted, ...refused], true), [...accepted.map(() => true), ...refused.map(() => false)]);
});

test("creation sharing and adoption refuse off-shape identities without changing the JS store", () => {
  for (const id of refused) {
    const api = profiles(id);
    const before = api.state();
    assert.throws(() => before.createProfile({ name: "Rejected" }), /generated lowercase/);
    assert.equal(api.state(), before);
    assert.throws(() => before.updateProfile("default", { id }), /generated lowercase/);
    assert.throws(() => before.updateProfile("default", { dataId: id }), /generated lowercase/);
    assert.equal(api.state(), before);
    before.profiles[id] = before.profiles.default;
    assert.throws(() => before.createProfile({ name: "Sharing via alias", shareWith: id }), /generated lowercase/);
    assert.equal(api.state(), before);
    before.profiles[id] = { ...before.profiles.default, id };
    assert.throws(() => before.createProfile({ name: "Sharing", shareWith: id }), /generated lowercase/);
    assert.equal(api.state(), before);
  }
  for (const id of accepted) {
    const api = profiles(id);
    const created = api.state().createProfile({ name: "Accepted" });
    assert.equal(created, id);
    api.state().updateProfile("default", { dataId: id });
    assert.equal(api.state().profiles.default.dataId, id);
  }
});

const canon = load("../../../../packages/sync/src/canon.ts", {});
const hlc = load("../../../../packages/sync/src/hlc.ts", {});
const scope = load("../../../../packages/sync/src/scope.ts", { "./canon.ts": canon, "./hlc.ts": hlc });

test("sync keeps off-shape identity records unapplied and the previous profile visible", async () => {
  const api = profiles();
  const previous = api.state().profiles.default;
  const state = scope.emptyScope();
  const key = "prof:default";
  state.records[key] = { h: "000000001.0000.remote", v: { dataId: "p-MixedCase-1" }, o: ["remote", 1] };
  state.base[key] = canon.canonical({ dataId: "default" });
  state.unapplied = [key];
  const base = state.base[key];
  await scope.syncScope({ scope: "app", state, transport: {
    read: async () => ({ files: [], pending: [], damaged: [], present: [] }),
    write: async () => { throw new Error("Unexpected write"); }, remove: async () => { throw new Error("Unexpected remove"); },
  }, adapters: [{ prefix: "prof:", extract: () => null, apply(visible) { api.state().updateProfile("default", visible.get(key)); } }],
  clock: new hlc.Clock("local", null, () => 1), device: "local", now: () => 1 });
  assert.equal(api.state().profiles.default, previous);
  assert.deepEqual([...state.unapplied], [key]);
  assert.equal(state.base[key], base);
});

test("disk hydration keeps saved off-shape ids while live hydration refuses them", async () => {
  const { useBrowser } = await import("./browser.ts");
  const { withApplier } = await import("./nativeStore.ts");
  const before = useBrowser.getState();
  const profile = { ...before.profiles.default, id: "Saved-MixedCase", dataId: "Saved-Data" };
  const saved = JSON.parse(JSON.stringify({ profiles: { [profile.id]: profile }, profileOrder: [profile.id] }));
  try {
    useBrowser.getState().hydrate(saved);
    assert.deepEqual(useBrowser.getState().profiles[profile.id], profile);
    withApplier(() => useBrowser.getState().hydrate(saved));
    assert.deepEqual(useBrowser.getState().profiles[profile.id], profile);
    useBrowser.getState().updateProfile(profile.id, { name: "Still visible" });
    assert.equal(useBrowser.getState().profiles[profile.id].name, "Still visible");
    assert.throws(() => useBrowser.getState().createProfile({ name: "Sharing", shareWith: profile.id }), /generated lowercase/);
  } finally {
    withApplier(() => useBrowser.setState(before, true));
  }
});

test("both sync lanes keep metadata for saved off-shape profiles unapplied", async () => {
  const { useBrowser } = await import("./browser.ts");
  const { withApplier } = await import("./nativeStore.ts");
  const { profilesAdapter } = await import("../sync/adapters.ts");
  const { syncRedesign } = await import("../sync/redesignSwitch.ts");
  const before = useBrowser.getState();
  const originalLane = syncRedesign.on;
  const profile = { ...before.profiles.default, id: "Saved-MixedCase" };
  try {
    withApplier(() => useBrowser.getState().hydrate({ profiles: { [profile.id]: profile }, profileOrder: [profile.id] }));
    for (const lane of [false, true]) {
      syncRedesign.on = lane;
      const state = scope.emptyScope();
      const key = "prof:remote-profile";
      state.records[key] = { h: "000000001.0000.remote", v: { n: "Remote rename", c: "blue", i: null }, o: ["remote", 1] };
      state.base[key] = canon.canonical({ n: profile.name, c: profile.color, i: profile.icon });
      state.unapplied = [key];
      const base = state.base[key];
      await scope.syncScope({ scope: "app", state, transport: {
        read: async () => ({ files: [], pending: [], damaged: [], present: [] }),
        write: async () => { throw new Error("Unexpected write"); }, remove: async () => { throw new Error("Unexpected remove"); },
      }, adapters: [{ ...profilesAdapter(() => ({ [profile.id]: { syncId: "remote-profile" } })), extract: () => null }],
      clock: new hlc.Clock("local", null, () => 1), device: "local", now: () => 1 });
      assert.equal(useBrowser.getState().profiles[profile.id].name, profile.name);
      assert.deepEqual([...state.unapplied], [key]);
      assert.equal(state.base[key], base);
    }
  } finally {
    syncRedesign.on = originalLane;
    withApplier(() => useBrowser.setState(before, true));
  }
});

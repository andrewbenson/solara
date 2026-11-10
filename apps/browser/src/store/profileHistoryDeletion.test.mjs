import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { createRequire } from "node:module";
import { test } from "node:test";
import { runInNewContext } from "node:vm";

const ts = createRequire(import.meta.url)("typescript");
const bookmarkProjection = await import("./bookmarkProjection.ts");
function load(path, imports) {
  const module = { exports: {} };
  const source = readFileSync(new URL(path, import.meta.url), "utf8");
  runInNewContext(ts.transpileModule(source, { compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2022 } }).outputText, {
    exports: module.exports,
    require: (name) => {
      if (name in imports) return imports[name];
      throw new Error(`Unexpected import ${name}`);
    },
    Map, Set, console,
  });
  return module.exports;
}
const without = (table, ids) => Object.fromEntries(Object.entries(table).filter(([id]) => !new Set(ids).has(id)));
const model = { without, setSharedDataIds: () => {}, viewTabIds: () => [] };
const bookmarks = { bookmarkRoots: () => null };
function fixture({ shared = false, record = () => {} } = {}) {
  const id = "p-work-1";
  let state = {
    profiles: { default: { id: "default" }, [id]: { id, ...(shared ? { dataId: "default" } : {}) } },
    profileOrder: ["default", id], orphanedProfileData: [], windows: {}, tabs: {}, groups: {},
    closedTabs: [], cleanedTabs: [], closedGroups: [], deletedGroups: [], closedWindows: [], parkedPins: {},
    settings: { defaultProfileId: "default" }, bookmarks: { roots: {} },
    history: { default: ["kept"], [id]: ["gone"] }, historyReady: { default: true, [id]: true }, historyFloor: { default: 7, [id]: 8 },
  };
  const profiles = load("./profiles.ts", {
    "./bookmarkProjection": bookmarkProjection,
    "@solara/shell": {}, "./bookmarks": bookmarks, "./model": model, "./settings": { DEFAULT_PROFILE_ID: "default" },
    "./nativeStore": { nativeSafeMode: () => false, confirmNativeProfileDeletion: record }, "./tabs": { removeTabs: (s) => s },
  });
  const get = () => state;
  const set = (patch) => { state = { ...state, ...(typeof patch === "function" ? patch(state) : patch) }; };
  const actions = profiles.createProfilesSlice(set, get, { subscribe: () => {} });
  return { id, get, remove: () => actions.deleteProfile(id) };
}

for (const shared of [false, true]) test(`JS deletion prunes only the removed alias history state (shared=${shared})`, () => {
  const f = fixture({ shared });
  f.remove();
  assert.equal(f.get().history[f.id], undefined);
  assert.equal(f.get().historyReady[f.id], undefined);
  assert.equal(f.get().historyFloor[f.id], undefined);
  assert.equal(f.get().historyReady.default, true);
  assert.equal(f.get().historyFloor.default, 7);
  assert.deepEqual(f.get().history.default, ["kept"]);
  assert.equal(f.get().orphanedProfileData.includes(""), false);
  assert.equal(f.get().orphanedProfileData.includes(f.id), !shared);
});

test("native profileDeleted effect prunes only the alias, preserving the common state", () => {
  const workspace = load("./nativeWorkspace.ts", {
    "./bookmarkProjection": bookmarkProjection,
    "@solara/solaracore": {}, "./bookmarks": bookmarks, "./model": model, "./closingWindowRestore": {}, "./tabs": {},
    "../lib/earlyNavigate": {}, "../lib/focusClaims": {}, "./nativeStore": { nativeOwnsWorkspace: () => true },
  });
  const f = fixture({ shared: true });
  let state = f.get();
  workspace.runEffects([{ type: "profileDeleted", profileId: f.id, shared: true }], () => state, (patch) => { state = { ...state, ...patch }; });
  assert.equal(state.historyReady[f.id], undefined);
  assert.equal(state.historyFloor[f.id], undefined);
  assert.equal(state.historyReady.default, true);
  assert.equal(state.historyFloor.default, 7);
});

test("fallback records confirmation while the profile and all its state are still present", () => {
  let recorded = false;
  const f = fixture({ record: (id) => {
    assert.equal(id, f.id);
    assert.ok(f.get().profiles[id]);
    assert.ok(f.get().history[id]);
    assert.equal(f.get().orphanedProfileData.length, 0);
    recorded = true;
  } });
  f.remove();
  assert.equal(recorded, true);
  assert.equal(f.get().profiles[f.id], undefined);
});

test("fallback ledger refusal leaves every slice and the cleanup queue unchanged", () => {
  const f = fixture({ record: () => { throw new Error("ledger full"); } });
  const before = f.get();
  assert.throws(f.remove, /ledger full/);
  assert.equal(f.get(), before);
});

function nativeBridge({ present = true, active = true, dispatch = () => ({ rev: 1, effects: [{ type: "profileDeleted", profileId: "p-work-1" }] }) } = {}) {
  const native = load("./nativeStore.ts", {
    "./bookmarkProjection": bookmarkProjection,
    "@solara/store": {
      nativeStoreModulePresent: () => present,
      nativeStoreStatus: () => ({ active, scope: "settingsAndDownloads" }),
      nativeDispatch: dispatch,
      installPageReportWriter: () => {},
    },
    "./closingWindowRestore": {}, "../sync/redesignSwitch": { syncRedesign: { on: false } },
    "./syncOrigin": { applyingFromSync: () => false }, "./nativeWorkspace": {},
  });
  native.startNativeStore();
  return native;
}

test("fallback uses the existing native deleteProfile command for confirmation", () => {
  const commands = [];
  const native = nativeBridge({ dispatch: (command) => { commands.push(command); return { rev: 1, effects: [{ type: "profileDeleted", profileId: "p-work-1" }] }; } });
  native.confirmNativeProfileDeletion("p-work-1");
  assert.equal(commands.length, 1);
  assert.equal(commands[0].name, "deleteProfile");
  assert.deepEqual([...commands[0].args], ["p-work-1"]);
});

for (const options of [
  { active: false },
  { dispatch: () => ({ rev: 1, effects: [] }) },
  { dispatch: () => ({ rev: 1, effects: [{ type: "profileDeleted", profileId: "P-work-1" }] }) },
  { dispatch: () => ({ rev: 1, error: "ledger full" }) },
]) test("a present native store must confirm the exact alias before fallback removal", () => {
  assert.throws(() => nativeBridge(options).confirmNativeProfileDeletion("p-work-1"), /confirm profile deletion|ledger full/);
});

test("module-absent fallback keeps the profile and queue intact because it cannot record confirmation", () => {
  const native = nativeBridge({ present: false, active: false, dispatch: () => { assert.fail("No native module"); } });
  const f = fixture({ record: native.confirmNativeProfileDeletion });
  const before = f.get();
  assert.throws(f.remove, /native confirmation ledger/);
  assert.equal(f.get(), before);
});

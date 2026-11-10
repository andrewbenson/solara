import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { createRequire } from "node:module";
import { test } from "node:test";
import { runInNewContext } from "node:vm";
import { declaration, runNative, source } from "../test-native/safe-host/run.mjs";

const ts = createRequire(import.meta.url)("typescript");
const bookmarkProjection = await import("./bookmarkProjection.ts");
const read = (path) => readFileSync(new URL(path, import.meta.url), "utf8");
const compile = (source) => ts.transpileModule(source, { compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2022 } }).outputText;
const warnings = [];
const quietConsole = { warn: (...args) => warnings.push(args) };

function load(path, imports = {}) {
  const module = { exports: {} };
  runInNewContext(compile(read(path)), {
    exports: module.exports,
    require: (name) => {
      if (name in imports) return imports[name];
      throw new Error(`Unexpected import: ${name}`);
    },
    console: quietConsole,
    Map, Set, WeakMap, setTimeout,
  });
  return module.exports;
}

const canon = load("../../../../packages/sync/src/canon.ts");
const hlc = load("../../../../packages/sync/src/hlc.ts");
const scope = load("../../../../packages/sync/src/scope.ts", { "./canon.ts": canon, "./hlc.ts": hlc });

function bridge(dispatch, redesign) {
  const origins = load("./syncOrigin.ts");
  const native = load("./nativeStore.ts", {
    "./bookmarkProjection": bookmarkProjection,
    "@solara/store": {
      nativeStoreStatus: () => ({ active: true, scope: "everything", syncRedesign: redesign }),
      nativeStoreModulePresent: () => true,
      useNativeSyncOrigins: () => true,
      nativeDispatch: dispatch,
      installPageReportWriter: () => {},
    },
    "./closingWindowRestore": {},
    "../sync/redesignSwitch": { syncRedesign: { on: redesign } },
    "./syncOrigin": origins,
    "./nativeWorkspace": {},
  });
  native.startNativeStore();
  return { native, origins };
}

for (const redesign of [false, true]) for (const deleted of [false, true]) {
  test(`${deleted ? "a deleted name stays unapplied until replaced" : "the same pending adoption retries once legitimate"} (${redesign ? "redesign" : "legacy"})`, async () => {
    const session = { profiles: { adopter: { id: "adopter", dataId: "active" } } };
    const before = structuredClone(session);
    let pending = true;
    let failures = 0;
    const { native, origins } = bridge((command) => {
      if (command.args[1].dataId === "retired" && (pending || deleted)) return { rev: 0, error: pending ? "Profile data retired is pending deletion." : "Profile data retired was deleted and cannot be reused." };
      session.profiles[command.args[0]].dataId = command.args[1].dataId;
      return { rev: 1, patches: [] };
    }, redesign);
    const key = "prof:adopter";
    const value = { dataId: "retired" };
    const state = scope.emptyScope();
    state.records[key] = { h: "000000001.0000.remote", v: value, o: ["remote", 1] };
    state.base[key] = canon.canonical({ dataId: "active" });
    state.unapplied = [key];
    const base = state.base[key];
    const adapter = {
      prefix: "prof:",
      extract: () => null,
      apply(visible) {
        const apply = () => native.nativeWrite({ name: "updateProfile", args: ["adopter", visible.get(key)] });
        try { if (redesign) origins.asSyncOrigin(apply); else apply(); }
        catch (error) { failures++; assert.match(error.message, /pending deletion|was deleted/); throw error; }
      },
    };
    const transport = {
      read: async () => ({ files: [], pending: [], damaged: [], present: [] }),
      write: async () => { throw new Error("Unexpected write"); },
      remove: async () => { throw new Error("Unexpected remove"); },
    };
    const cycle = () => scope.syncScope({ scope: "app", state, transport, adapters: [adapter], clock: new hlc.Clock("local", null, () => 1), device: "local", now: () => 1 });
    await cycle();
    assert.equal(failures, 1);
    assert.deepEqual(session, before);
    assert.deepEqual([...state.unapplied], [key]);
    assert.equal(state.base[key], base);
    pending = false;
    await cycle();
    if (!deleted) {
      assert.equal(failures, 1);
      assert.equal(session.profiles.adopter.dataId, value.dataId);
      assert.deepEqual([...state.unapplied], []);
      assert.equal(state.base[key], canon.canonical(value));
      return;
    }
    assert.equal(failures, 2);
    assert.deepEqual(session, before);
    assert.deepEqual([...state.unapplied], [key]);
    assert.equal(state.base[key], base);
    const fresh = { dataId: "fresh-never-deleted" };
    state.records[key] = { h: "000000002.0000.remote", v: fresh, o: ["remote", 2] };
    await cycle();
    assert.equal(failures, 2);
    assert.equal(session.profiles.adopter.dataId, fresh.dataId);
    assert.deepEqual([...state.unapplied], []);
    assert.equal(state.base[key], canon.canonical(fresh));
  });
}

for (const name of ["createProfile", "updateProfile", "deleteProfile", "hydrate", "applyState"]) {
  test(`${name} exposes a native profile-data refusal synchronously`, () => {
    const { native } = bridge(() => ({ rev: 0, error: "Profile data retired is pending deletion" }), false);
    assert.throws(() => native.nativeWrite({ name, args: [] }), /pending deletion/);
  });
}

test("Settings replies with a ledger-write deletion refusal without an unhandled rejection", async () => {
  const { native } = bridge(() => ({ rev: 0, error: "Profile deletion history could not be written" }), false);
  const settings = read("../../../../packages/settings/src/index.ts");
  const start = settings.indexOf("export function serveNativeSettings(");
  const end = settings.indexOf("\nexport *", start);
  let receive;
  let reply;
  let replied;
  const completed = new Promise((resolve) => { replied = resolve; });
  const module = { exports: {} };
  runInNewContext(compile(settings.slice(start, end)), {
    exports: module.exports,
    native: {
      addListener: (_, listener) => { receive = listener; },
      reply: (...args) => { reply = args; replied(); return Promise.resolve(); },
    },
  });
  module.exports.serveNativeSettings({ "profiles.delete": (id) => native.nativeWrite({ name: "deleteProfile", args: [id] }) });
  receive({ id: 7, name: "profiles.delete", args: '["named"]' });
  await completed;
  assert.equal(reply[0], 7);
  assert.equal(reply[1], null);
  assert.match(reply[2], /Profile deletion history could not be written/);
  await new Promise((resolve) => setImmediate(resolve));
});

test("Settings returns from details after confirmed deletion and keeps details on refusal", () => {
  const adapter = source("packages/settings/ios/Adapters/ProfilesAdapter.swift");
  const production = [
    "@MainActor final class ProfilesAdapter {",
    "let store = StoreSource()",
    "private var pending: (base: [ProfileSummary], profiles: [ProfileSummary])?",
    "static func summary(_ profile: ProfileSummary) -> ProfileSummary { profile }",
    declaration(adapter, "var profiles: [ProfileSummary]"),
    declaration(adapter, "func deleteProfile(_ id:"),
    "}",
    "@MainActor final class ProfilesPaneModel {",
    "let services: ProfilesAdapter; let safeMode = false; var deletePrompt: ProfileDeletePrompt?",
    "init(services: ProfilesAdapter) { self.services = services }",
    "var profiles: [ProfileSummary] { services.profiles }",
    "func profile(_ id: String) -> ProfileSummary? { profiles.first { $0.id == id } }",
    declaration(source("native/SolaraKit/Sources/SolaraUI/Settings/Panes/ProfilesPane.swift"), "func confirmDelete("),
    "}",
    "enum SettingsAdapters {",
    declaration(source("packages/settings/ios/Adapters/SettingsAdapters.swift"), "static func jsThrowing(_ name:"),
    "}",
  ].join("\n");
  const results = runNative("ProfilesAdapter.swift", production, [], true);
  assert.equal(results.length, 2);
  for (const result of results) {
    assert.equal(result.visibleBeforeReply, true);
    assert.equal(result.detailsBeforeReply, true);
    assert.equal(result.noBlankPane, true);
    assert.equal(result.failed, result.refused);
    assert.equal(result.detailsAfterReply, result.refused);
  }
});

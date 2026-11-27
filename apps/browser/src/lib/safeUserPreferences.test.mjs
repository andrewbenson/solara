import assert from "node:assert/strict";
import { createRequire } from "node:module";
import { test } from "node:test";
import vm from "node:vm";
import { declaration, runNative, source } from "../test-native/safe-host/run.mjs";

const ts = createRequire(import.meta.url)("typescript");
const onboarding = "apps/browser/src/components/onboarding/state.ts";

function compile(path, signatures, globals) {
  const text = signatures.map((name) => declaration(source(path), name).replace(/^export /, "")).join("\n");
  const program = ts.transpileModule(text, { compilerOptions: { target: ts.ScriptTarget.ES2022, module: ts.ModuleKind.None } }).outputText;
  const context = vm.createContext({ console, Date, Promise, __DEV__: false, ...globals });
  vm.runInContext(program, context);
  return context;
}

function documents(safe) {
  const files = new Map();
  const writes = [];
  return {
    files, writes,
    globals: {
      nativeSafeMode: () => safe,
      readDocument: (name) => files.get(name) ?? null,
      writeDocument: (name, value) => { writes.push(name); files.set(name, value); },
    },
  };
}

test("automatic onboarding detection leaves documents unchanged in safe mode and completes detection normally", () => {
  for (const safe of [true, false]) {
    const fixture = documents(safe);
    fixture.files.set("session.json", "{}");
    let completed = 0;
    const context = compile(onboarding, ["export function maybeStartOnboarding("], {
      ...fixture.globals, persistenceRefused: () => false, readSaved: () => null,
      hostedKinds: () => ["onboarding"], markCompleted: () => completed++,
    });
    context.maybeStartOnboarding();
    assert.equal(completed, safe ? 0 : 1);
    assert.equal(fixture.files.get("session.json"), "{}");
  }
});

test("explicit onboarding progress persists into a normal read of the same documents", () => {
  const fixture = documents(true);
  const initial = JSON.stringify({ version: 1, completedAt: null, step: "source" });
  fixture.files.set("onboarding.json", initial);
  const progress = compile(onboarding, ["function readSaved(", "function save("], { ...fixture.globals, DOC: "onboarding.json", persistenceRefused: () => false });
  progress.save({ step: "look", introMusicMuted: true });
  const resumed = compile(onboarding, ["function readSaved("], { ...fixture.globals, DOC: "onboarding.json", nativeSafeMode: () => false });
  assert.equal(resumed.readSaved().step, "look");
  assert.equal(resumed.readSaved().introMusicMuted, true);
  assert.deepEqual(fixture.writes, ["onboarding.json"]);
});

test("native CLI installation keeps explicit effects and refuses both automatic upgrade entries", () => {
  const text = source("packages/settings/ios/Services/NativeCliControl.swift");
  const production = ["func install(reason:", "private func upgradeIfBehind(", "private func installed(", "private static func readSaved(", "private static func save("].map((name) => declaration(text, name)).join("\n");
  const results = runNative("UserPreferences.swift", production, [], true);
  for (const result of results) {
    const refused = result.safe && result.reason !== "settings";
    assert.equal(result.installs, refused ? 0 : 1);
    assert.equal(result.writes, refused ? 0 : 1);
    if (!refused) {
      assert.equal(result.saved.binPath, "/fixture/bin/solara");
      assert.equal(result.saved.version, "1.0");
    }
    if (refused && result.reason === "upgrade") {
      assert.equal(result.reply.ok, false);
      assert.match(result.reply.error, /safe mode/i);
    }
  }
});

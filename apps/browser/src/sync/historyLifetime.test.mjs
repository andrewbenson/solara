import assert from "node:assert/strict";
import { test } from "node:test";
import { startProfileConfirmation } from "../test-native/profileConfirmation.mjs";

let hold = null;
const calls = [];
globalThis.acTestNativeModules = {
  SolaraSettings: {
    libraryCommand: async (kind, engine, payload) => {
      calls.push({ kind, engine, payload });
      if (kind === "addHistoryVisits" && payload.pages.length && hold) {
        hold.entered.resolve();
        await hold.release.promise;
      }
      return kind === "addHistoryVisits" ? payload.pages.length : undefined;
    },
  },
};

const { useBrowser } = await import("../store/browser.ts");
const { historyAdapter, profilesAdapter } = await import("./adapters.ts");
const { canonical, Clock, emptyScope, syncScope } = await import("@solara/sync");
const { withApplier } = await import("../store/nativeStore.ts");
await startProfileConfirmation();
const S = () => useBrowser.getState();
const key = "h:https://remote.example/";
const value = () => ({ t: "Remote", n: 1, vt: [Date.now() - 1000] });

const deferred = () => {
  let resolve;
  const promise = new Promise((done) => { resolve = done; });
  return { promise, resolve };
};

async function deadline(promise) {
  let timer;
  try {
    return await Promise.race([promise, new Promise((_, reject) => { timer = setTimeout(() => reject(new Error("history continuation deadline")), 1000); })]);
  } finally {
    clearTimeout(timer);
  }
}

function setup() {
  S().hydrate({});
  const id = S().createProfile({ name: "Delete me" });
  useBrowser.setState({ historyReady: { [id]: true }, history: { [id]: [] }, historyFloor: { [id]: -Infinity } });
  calls.length = 0;
  return id;
}

for (const writtenKeysOnly of [false, true]) for (const change of ["delete", "delete and restore exact object", "replace lifetime", "retire engine", "retire then finish cleanup"]) {
  test(`history apply refuses its keys when ${change} happens during native work (writtenKeysOnly=${writtenKeysOnly})`, { timeout: 5000 }, async () => {
    const before = S();
    const id = setup();
    const captured = S().profiles[id];
    const state = emptyScope();
    const v = value();
    state.records[key] = { h: "000000001.0000.remote", v, o: ["remote", 1] };
    state.unapplied = [key];
    state.base[key] = canonical({ t: "Old", n: 0, vt: [] });
    const originalBase = state.base[key];
    hold = { entered: deferred(), release: deferred() };
    const run = syncScope({
      scope: "p:remote", state,
      transport: {
        read: async () => ({ files: [], pending: [], damaged: [], present: [] }),
        write: async () => { assert.fail("Refused history must not publish"); },
        remove: async () => { assert.fail("Unexpected compaction"); },
      },
      adapters: [historyAdapter(id)], clock: new Clock("local"), device: "local", options: { writtenKeysOnly },
    });
    try {
      await deadline(hold.entered.promise);
      if (change.startsWith("delete")) {
        S().deleteProfile(id);
        if (change !== "delete") useBrowser.setState((s) => ({ profiles: { ...s.profiles, [id]: captured }, profileOrder: [...s.profileOrder, id], historyReady: { [id]: true } }));
      } else if (change === "replace lifetime") useBrowser.setState((s) => ({ profiles: { ...s.profiles, [id]: { ...captured, createdAt: captured.createdAt + 1 } } }));
      else {
        useBrowser.setState({ orphanedProfileData: [id] });
        if (change === "retire then finish cleanup") useBrowser.setState({ orphanedProfileData: [] });
      }
      hold.release.resolve();
      await deadline(run);
      assert.deepEqual(S().history[id] ?? [], [], "no rows from the retired lifetime reach JS");
      if (change === "delete") assert.equal(Object.hasOwn(S().history, id), false);
      assert.deepEqual(state.unapplied, [key]);
      assert.equal(state.base[key], originalBase);
    } finally {
      hold.release.resolve();
      await deadline(run);
      hold = null;
      withApplier(() => useBrowser.setState(before, true));
    }
  });
}

test("history refuses a missing or retired profile before native work and extraction abstains", { timeout: 5000 }, async () => {
  const before = S();
  const id = setup();
  try {
    const adapter = historyAdapter(id);
    S().deleteProfile(id);
    useBrowser.setState({ historyReady: { [id]: true } });
    assert.equal(adapter.extract(() => undefined), null);
    assert.equal(await adapter.apply(new Map([[key, value()]]), new Set([key])), false);
    assert.deepEqual(calls, []);
  } finally {
    withApplier(() => useBrowser.setState(before, true));
  }
});

test("a rename during native work preserves the profile lifetime", { timeout: 5000 }, async () => {
  const before = S();
  const id = setup();
  hold = { entered: deferred(), release: deferred() };
  const run = historyAdapter(id).apply(new Map([[key, value()]]), new Set([key]));
  try {
    await deadline(hold.entered.promise);
    S().updateProfile(id, { name: "Renamed" });
    hold.release.resolve();
    await deadline(run);
    assert.equal(S().history[id]?.[0].url, key.slice(2));
  } finally {
    hold.release.resolve();
    await deadline(run);
    hold = null;
    withApplier(() => useBrowser.setState(before, true));
  }
});

test("remote profile metadata and history cannot recreate a deleted local identity", { timeout: 5000 }, async () => {
  const before = S();
  const id = setup();
  try {
    const adapter = historyAdapter(id);
    const metadata = profilesAdapter(() => ({ [id]: { syncId: "remote" } }));
    S().deleteProfile(id);
    metadata.apply(new Map([["prof:remote", { n: "Remote rename", c: "blue", i: null }]]), new Set(["prof:remote"]), () => undefined, { known: () => false });
    assert.equal(await adapter.apply(new Map([[key, value()]]), new Set([key])), false);
    assert.equal(S().profiles[id], undefined);
    assert.equal(S().history[id], undefined);
    assert.deepEqual(calls, []);
  } finally {
    withApplier(() => useBrowser.setState(before, true));
  }
});

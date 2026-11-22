import assert from "node:assert/strict";
import { test } from "node:test";
import { fixedBy } from "./switchOn.mjs";

const fake = {
  rev: 0,
  settings: null,
  choose: null,
  sent: [],
  held: false,
  commitListeners: [],
  status: () => ({ active: true }),
  snapshot() {
    return JSON.stringify({ rev: this.rev, data: { settings: this.settings, downloads: [] } });
  },
  settle(patch, fromSync) {
    const next = fromSync ? { ...this.settings, ...patch } : this.choose(this.settings, patch);
    const set = Object.fromEntries(Object.entries(next).filter(([k, v]) => JSON.stringify(v) !== JSON.stringify(this.settings[k])));
    this.settings = next;
    return { rev: ++this.rev, settings: { set } };
  },
  dispatch(json) {
    const parsed = JSON.parse(json);
    const token = !Array.isArray(parsed) && !!parsed.fromSync;
    const commands = [].concat(parsed.commands ?? parsed);
    this.sent.push({ token, names: commands.map((c) => c.name) });
    if (token && this.held && !commands.every((c) => c.name === "endFromSync")) return JSON.stringify({ rev: this.rev, patches: [], busy: true });
    const patches = [];
    for (const { name, args } of commands) {
      if (name === "beginTransaction") this.held = true;
      if (name === "endTransaction") this.held = false;
      if (name === "applyState" && args[0]?.settings) {
        patches.push({ ...this.settle(args[0].settings, true), bridge: true, ...(token ? { sync: true } : {}) });
        continue;
      }
      if (name !== "updateSettings") continue;
      const [patch, options] = args;
      patches.push({ ...this.settle(patch, !!options?.fromSync), bridge: true, ...(token ? { sync: true } : {}) });
    }
    return JSON.stringify({ rev: this.rev, patches });
  },
  catchUp: () => null,
  flush: () => true,
  freeze: () => true,
  useSyncOrigins: () => true,
  addListener(_event, listener) {
    this.commitListeners.push(listener);
    return { remove: () => (this.commitListeners = this.commitListeners.filter((l) => l !== listener)) };
  },
  foreign(patch, effects) {
    const commit = { rev: patch.rev, patch, ...(effects ? { effects } : {}) };
    for (const listener of this.commitListeners) listener({ event: JSON.stringify(commit) });
  },
};
globalThis.acTestNativeModules = { ...globalThis.acTestNativeModules, SolaraStoreAdapter: fake };

const { useBrowser } = await import("../../store/browser.ts");
const settingsModule = await import("../../store/settings.ts");
const nativeStore = await import("../../store/nativeStore.ts");
const { Clock } = await import("@solara/sync");
const { openJournal } = await import("../editJournal.ts");
const { journalCommands } = await import("../commandJournal.ts");
const { settingsAdapter } = await import("../adapters.ts");
const { fromSync } = await import("../../store/pinOrderChoices.ts");
const S = () => useBrowser.getState();

function journaled() {
  S().hydrate({});
  fake.choose = settingsModule.choose;
  fake.settings = S().settings;
  fake.sent = [];
  assert.ok(nativeStore.startNativeStore().active, "control: the native store fake is active");
  nativeStore.attachReplica(useBrowser);
  const docs = new Map();
  const journal = openJournal({ read: (n) => docs.get(n) ?? null, write: (n, t) => docs.set(n, t) }, { storeG: 0 });
  const stop = journalCommands(journal, new Clock("dev1"), () => [{ scope: "app", adapter: settingsAdapter, sources: (s) => [s.settings] }], () => undefined);
  return { journal, stop };
}

test("FOLLOW-token: a write made inside a sync apply carries the sync token to Swift; one made outside doesn't", fixedBy("step 5"), () => {
  const { stop } = journaled();
  try {
    fromSync(() => S().updateSettings({ searchEngine: "bing" }, { fromSync: true }));
    S().updateSettings({ appearance: "dark" });
    const settingsWrites = fake.sent.filter((s) => s.names.includes("updateSettings"));
    assert.deepEqual(settingsWrites.map((s) => s.token), [true, false]);
  } finally {
    stop();
  }
});

test("FOLLOW-derived: a change Swift derives from a sync apply and commits later arrives tagged and isn't journaled; an untagged one is", fixedBy("step 5"), () => {
  const { journal, stop } = journaled();
  try {
    const engine = S().settings.searchEngine === "bing" ? "duckduckgo" : "bing";
    const derived = fake.settle({ searchEngine: engine, chosen: [...new Set([...(fake.settings.chosen ?? []), "searchEngine"])] }, true);
    fake.foreign({ ...derived, sync: true });
    assert.equal(S().settings.searchEngine, engine, "control: the derived change reached the replica");
    assert.equal(journal.entry("app", "set:searchEngine"), undefined, "the derived change isn't journaled");
    const want = S().settings.appearance === "dark" ? "light" : "dark";
    const fromUI = fake.settle({ appearance: want, chosen: [...new Set([...(fake.settings.chosen ?? []), "appearance"])] }, true);
    fake.foreign(fromUI);
    assert.deepEqual(journal.entry("app", "set:appearance")?.v, { v: want }, "a native UI change is");
  } finally {
    stop();
  }
});

test("TXN-sync: a sync apply that lands during a user's native transaction comes back busy and applies nothing; retried after it, it isn't journaled while the user's edit is", fixedBy("step 5"), () => {
  const { journal, stop } = journaled();
  try {
    const engine = S().settings.searchEngine === "bing" ? "duckduckgo" : "bing";
    const look = S().settings.appearance === "dark" ? "light" : "dark";
    const syncApply = () => fromSync(() => S().updateSettings({ searchEngine: engine, chosen: [...new Set([...(S().settings.chosen ?? []), "searchEngine"])] }, { fromSync: true }));
    nativeStore.nativeTransaction(() => {
      assert.throws(syncApply, nativeStore.NativeStoreBusy, "the sync apply doesn't join the user's transaction");
      assert.notEqual(S().settings.searchEngine, engine, "control: nothing of it landed");
      S().updateSettings({ appearance: look });
    });
    syncApply();
    assert.equal(S().settings.searchEngine, engine, "control: the retry landed once the transaction ended");
    assert.equal(journal.entry("app", "set:searchEngine"), undefined, "the retried sync apply isn't journaled");
    assert.deepEqual(journal.entry("app", "set:appearance")?.v, { v: look }, "the user's edit is");
  } finally {
    stop();
  }
});

test("SWITCH-order: flipping syncRedesign after the native store started fails loudly instead of tagging with the wrong origins", fixedBy("step 5"), async () => {
  const { syncRedesign } = await import("../redesignSwitch.ts");
  const { stop } = journaled();
  try {
    syncRedesign.on = !syncRedesign.on;
    assert.throws(() => S().updateSettings({ appearance: "dark" }), /before the native store starts/);
  } finally {
    syncRedesign.on = !syncRedesign.on;
    stop();
  }
});

test("FOLLOW-effect-busy: an effect of a sync commit that comes back busy is retried after the user's transaction, and the effects after it still run", fixedBy("step 5"), async () => {
  const { onStoreEffect } = await import("../../store/nativeWorkspace.ts");
  const { journal, stop } = journaled();
  const ran = [];
  const engine = S().settings.searchEngine === "bing" ? "duckduckgo" : "bing";
  const stopProbe = onStoreEffect("probe-write", () => {
    ran.push("write");
    S().updateSettings({ searchEngine: engine, chosen: [...new Set([...(S().settings.chosen ?? []), "searchEngine"])] }, { fromSync: true });
  });
  const stopAfter = onStoreEffect("probe-after", () => ran.push("after"));
  try {
    fake.held = true;
    const commit = fake.settle({}, true);
    fake.foreign({ ...commit, sync: true }, [{ type: "probe-write" }, { type: "probe-after" }]);
    assert.deepEqual(ran, ["write", "after"], "the busy effect doesn't stop the ones after it");
    assert.notEqual(S().settings.searchEngine, engine, "control: the busy write didn't land");
    fake.held = false;
    await new Promise((r) => setTimeout(r, 150));
    assert.equal(S().settings.searchEngine, engine, "the retry landed once the transaction was over");
    assert.equal(journal.entry("app", "set:searchEngine"), undefined, "and it's sync's, so it isn't journaled");
  } finally {
    fake.held = false;
    stopProbe();
    stopAfter();
    stop();
  }
});

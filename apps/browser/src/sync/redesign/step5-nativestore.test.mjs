import assert from "node:assert/strict";
import { test } from "node:test";
import { fixedBy } from "./switchOn.mjs";

const replicaFake = {
  rev: 0,
  settings: null,
  choose: null,
  listeners: [],
  status: () => ({ active: true }),
  snapshot() {
    return JSON.stringify({ rev: this.rev, data: { settings: this.settings, downloads: [] } });
  },
  dispatch(json, sinceRev) {
    const commands = [].concat(JSON.parse(json).commands ?? JSON.parse(json));
    const patches = [];
    for (const { name, args } of commands) {
      if (name !== "updateSettings") continue;
      const [patch, options] = args;
      const next = options?.fromSync ? { ...this.settings, ...patch } : this.choose(this.settings, patch);
      const set = Object.fromEntries(Object.entries(next).filter(([k, v]) => JSON.stringify(v) !== JSON.stringify(this.settings[k])));
      this.settings = next;
      patches.push({ rev: ++this.rev, settings: { set } });
    }
    void sinceRev;
    return JSON.stringify({ rev: this.rev, patches });
  },
  catchUp: () => null,
  flush: () => true,
  freeze: () => true,
  useSyncOrigins: () => true,
  addListener: () => ({ remove() {} }),
};
globalThis.acTestNativeModules = { SolaraStoreAdapter: replicaFake };

const { useBrowser } = await import("../../store/browser.ts");
const settingsModule = await import("../../store/settings.ts");
const nativeStore = await import("../../store/nativeStore.ts");
const { Clock } = await import("@solara/sync");
const { openJournal } = await import("../editJournal.ts");
const { journalCommands } = await import("../commandJournal.ts");
const { settingsAdapter } = await import("../adapters.ts");
const { fromSync } = await import("../../store/pinOrderChoices.ts");
const S = () => useBrowser.getState();

test("D11-journal: with the native store owning settings, a change made here is journaled and sync's own write echoed back isn't", fixedBy("step 5"), () => {
  S().hydrate({});
  replicaFake.choose = settingsModule.choose;
  replicaFake.settings = S().settings;
  assert.ok(nativeStore.startNativeStore().active, "control: the native store fake is active");
  nativeStore.attachReplica(useBrowser);
  const docs = new Map();
  const journal = openJournal({ read: (n) => docs.get(n) ?? null, write: (n, t) => docs.set(n, t) }, { storeG: 0 });
  const stop = journalCommands(journal, new Clock("dev1"), () => [{ scope: "app", adapter: settingsAdapter, sources: (s) => [s.settings] }], () => undefined);
  try {
    fromSync(() => S().updateSettings({ appearance: "dark" }, { fromSync: true }));
    assert.equal(S().settings.appearance, "dark", "control: the replica took the native store's echo");
    assert.equal(journal.entry("app", "set:appearance"), undefined, "the echo isn't journaled");
    S().updateSettings({ appearance: "light" });
    assert.deepEqual(journal.entry("app", "set:appearance")?.v, { v: "light" }, "a change here is");
  } finally {
    stop();
  }
});

import assert from "node:assert/strict";
import { test } from "node:test";
import { fixedBy } from "./switchOn.mjs";

const fake = {
  rev: 0,
  settings: null,
  choose: null,
  uiEdit: null,
  status: () => ({ active: true }),
  snapshot() {
    return JSON.stringify({ rev: this.rev, data: { settings: this.settings, downloads: [] } });
  },
  dispatch(json, sinceRev) {
    const patches = [];
    if (this.uiEdit) {
      this.settings = { ...this.settings, ...this.uiEdit };
      patches.push({ rev: ++this.rev, settings: { set: this.uiEdit } });
      this.uiEdit = null;
    }
    for (const { name, args } of [].concat(JSON.parse(json).commands ?? JSON.parse(json))) {
      if (name !== "updateSettings") continue;
      const [patch, options] = args;
      const next = options?.fromSync ? { ...this.settings, ...patch } : this.choose(this.settings, patch);
      const set = Object.fromEntries(Object.entries(next).filter(([k, v]) => JSON.stringify(v) !== JSON.stringify(this.settings[k])));
      this.settings = next;
      patches.push({ rev: ++this.rev, bridge: true, settings: { set } });
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

test("ORIGIN-race: a native UI change that lands inside a sync write's window is still journaled; the sync write isn't", fixedBy("step 5"), () => {
  S().hydrate({});
  fake.choose = settingsModule.choose;
  fake.settings = S().settings;
  assert.ok(nativeStore.startNativeStore().active, "control: the native store fake is active");
  nativeStore.attachReplica(useBrowser);
  const docs = new Map();
  const journal = openJournal({ read: (n) => docs.get(n) ?? null, write: (n, t) => docs.set(n, t) }, { storeG: 0 });
  const stop = journalCommands(journal, new Clock("dev1"), () => [{ scope: "app", adapter: settingsAdapter, sources: (s) => [s.settings] }], () => undefined);
  try {
    fake.uiEdit = { appearance: "dark", chosen: [...new Set([...(fake.settings.chosen ?? []), "appearance"])] };
    fromSync(() => S().updateSettings({ searchEngine: "bing" }, { fromSync: true }));
    assert.equal(S().settings.appearance, "dark", "control: the UI change reached the replica");
    assert.equal(S().settings.searchEngine, "bing", "control: so did sync's write");
    assert.deepEqual(journal.entry("app", "set:appearance")?.v, { v: "dark" }, "the UI change is journaled");
    assert.equal(journal.entry("app", "set:searchEngine"), undefined, "sync's write isn't");
  } finally {
    stop();
  }
});

import assert from "node:assert/strict";
import { test } from "node:test";
import { fixedBy } from "./switchOn.mjs";

const sent = [];
const fake = {
  rev: 0,
  settings: null,
  choose: null,
  status: () => ({ active: true }),
  snapshot() {
    return JSON.stringify({ rev: this.rev, data: { settings: this.settings, downloads: [] } });
  },
  dispatch(json) {
    const parsed = JSON.parse(json);
    sent.push(parsed);
    if (!Array.isArray(parsed) && !parsed.name) return JSON.stringify({ rev: this.rev, error: "unknown command" });
    const patches = [];
    for (const { name, args } of [].concat(parsed)) {
      if (name !== "updateSettings") continue;
      const [patch, options] = args;
      const next = options?.fromSync ? { ...this.settings, ...patch } : this.choose(this.settings, patch);
      const set = Object.fromEntries(Object.entries(next).filter(([k, v]) => JSON.stringify(v) !== JSON.stringify(this.settings[k])));
      this.settings = next;
      patches.push({ rev: ++this.rev, settings: { set } });
      if (options?.fromSync && this.derive) {
        const derived = this.derive;
        this.derive = null;
        this.settings = { ...this.settings, ...derived };
        patches.push({ rev: ++this.rev, settings: { set: derived } });
      }
    }
    return JSON.stringify({ rev: this.rev, patches });
  },
  catchUp: () => null,
  flush: () => true,
  freeze: () => true,
  addListener: () => ({ remove() {} }),
};
globalThis.acTestNativeModules = { ...globalThis.acTestNativeModules, SolaraStoreAdapter: fake };

const { useBrowser } = await import("../../store/browser.ts");
const settingsModule = await import("../../store/settings.ts");
const nativeStore = await import("../../store/nativeStore.ts");
const { fromSync } = await import("../../store/pinOrderChoices.ts");
const S = () => useBrowser.getState();

test("FALLBACK: against a native store that doesn't advertise sync origins, a sync write goes out untagged, as today, even with syncRedesign on", fixedBy("step 5"), () => {
  S().hydrate({});
  fake.choose = settingsModule.choose;
  fake.settings = S().settings;
  assert.ok(nativeStore.startNativeStore().active, "control: the native store fake is active");
  nativeStore.attachReplica(useBrowser);
  const engine = S().settings.searchEngine === "bing" ? "duckduckgo" : "bing";
  sent.length = 0;
  fromSync(() => S().updateSettings({ searchEngine: engine }, { fromSync: true }));
  assert.ok(sent.length > 0, "control: the write reached the native store");
  assert.ok(sent.every((p) => Array.isArray(p) || typeof p.name === "string"), `no envelope is sent: ${JSON.stringify(sent)}`);
  assert.equal(S().settings.searchEngine, engine, "and the write lands");
});

test("FALLBACK-journal: with the native store unable to tag origins, the command journal stays off, so a change Swift derives from a sync apply isn't journaled as this Mac's", fixedBy("step 5"), async () => {
  const { Clock } = await import("@solara/sync");
  const { openJournal } = await import("../editJournal.ts");
  const { journalCommands } = await import("../commandJournal.ts");
  const { settingsAdapter } = await import("../adapters.ts");
  S().hydrate({});
  fake.choose = settingsModule.choose;
  fake.settings = S().settings;
  assert.ok(nativeStore.startNativeStore().active);
  nativeStore.attachReplica(useBrowser);
  const docs = new Map();
  const journal = openJournal({ read: (n) => docs.get(n) ?? null, write: (n, t) => docs.set(n, t) }, { storeG: 0 });
  const stop = journalCommands(journal, new Clock("dev1"), () => [{ scope: "app", adapter: settingsAdapter, sources: (s) => [s.settings] }], () => undefined);
  try {
    const look = S().settings.appearance === "dark" ? "light" : "dark";
    fake.derive = { appearance: look, chosen: [...new Set([...(S().settings.chosen ?? []), "appearance"])] };
    const engine = S().settings.searchEngine === "bing" ? "duckduckgo" : "bing";
    fromSync(() => S().updateSettings({ searchEngine: engine }, { fromSync: true }));
    assert.equal(S().settings.appearance, look, "control: a derived, untagged change reached the replica");
    assert.equal(journal.entry("app", "set:appearance"), undefined, "it isn't journaled as this Mac's edit");
    assert.equal(journal.g, 0, "nothing is");
  } finally {
    stop();
  }
});

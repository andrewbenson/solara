import "../../../../../native/SolaraKit/Scripts/legacy-bookmark-harness.mjs";
import assert from "node:assert/strict";
import { test } from "node:test";
import { fixedBy } from "./switchOn.mjs";

const replicaFake = {
  rev: 0,
  settings: null,
  choose: null,
  held: false,
  status: () => ({ active: true, scope: "settingsAndDownloads" }),
  snapshot() {
    return JSON.stringify({ rev: this.rev, data: { settings: this.settings, downloads: [] } });
  },
  dispatch(json) {
    const parsed = JSON.parse(json);
    const token = !Array.isArray(parsed) && !!parsed.fromSync;
    const commands = [].concat(parsed.commands ?? parsed);
    if (token && this.held && !commands.every((c) => c.name === "endFromSync")) return JSON.stringify({ rev: this.rev, patches: [], busy: true });
    const patches = [];
    for (const { name, args } of commands) {
      if (name !== "updateSettings") continue;
      const [patch, options] = args;
      const next = options?.fromSync ? { ...this.settings, ...patch } : this.choose(this.settings, patch);
      const set = Object.fromEntries(Object.entries(next).filter(([k, v]) => JSON.stringify(v) !== JSON.stringify(this.settings[k])));
      this.settings = next;
      patches.push({ rev: ++this.rev, bridge: true, ...(token ? { sync: true } : {}), settings: { set } });
    }
    return JSON.stringify({ rev: this.rev, patches });
  },
  catchUp: () => null,
  flush: () => true,
  freeze: () => true,
  useSyncOrigins: () => true,
  addListener: () => ({ remove() {} }),
};
globalThis.acTestNativeModules = { SolaraStoreAdapter: replicaFake };

const { S, settle, reset, onAndSynced, appMac, useBrowser } = await import("./harness.mjs");
const settingsModule = await import("../../store/settings.ts");
const nativeStore = await import("../../store/nativeStore.ts");

test("BUSY-retry: a sync apply that came back busy is retried after 400 ms, backing off while the store stays busy, and the poll returns to 15 s once it lands", fixedBy("step 5"), async () => {
  reset();
  replicaFake.choose = settingsModule.choose;
  replicaFake.settings = S().settings;
  assert.ok(nativeStore.startNativeStore().active, "control: the native store fake is active");
  nativeStore.attachReplica(useBrowser);
  const engine = await onAndSynced();
  const b = appMac("set:");
  await b.sync();
  const look = S().settings.appearance === "dark" ? "light" : "dark";
  b.store.set("set:appearance", { v: look });
  await b.sync();
  const stubbed = globalThis.setTimeout;
  let scheduled = [];
  globalThis.setTimeout = (fn, delay) => (scheduled.push({ fn, delay }), 0);
  const nextCycle = () => scheduled.filter((s) => s.delay >= 400).at(-1);
  const runNext = async () => {
    const next = nextCycle();
    scheduled = [];
    next.fn();
    await settle();
    return nextCycle()?.delay;
  };
  try {
    replicaFake.held = true;
    await engine.syncNow();
    await settle();
    assert.notEqual(S().settings.appearance, look, "control: the apply bounced while the user's transaction was open");
    assert.equal(nextCycle()?.delay, 400, `the next cycle comes soon after a busy apply (got ${scheduled.map((s) => s.delay).join(",")})`);
    assert.equal(await runNext(), 800, "a second bounce backs off");
    assert.equal(await runNext(), 1600);
    replicaFake.held = false;
    assert.equal(await runNext(), 15_000, "once the retry lands, the engine goes back to its normal poll");
    assert.equal(S().settings.appearance, look, "the retry landed");
  } finally {
    globalThis.setTimeout = stubbed;
    replicaFake.held = false;
  }
});

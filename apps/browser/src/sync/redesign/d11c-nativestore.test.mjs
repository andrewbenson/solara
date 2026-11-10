import "../../../../../native/SolaraKit/Scripts/legacy-bookmark-harness.mjs";
import assert from "node:assert/strict";
import { test } from "node:test";
import "./switchOn.mjs";

const replicaFake = {
  rev: 0,
  settings: null,
  choose: null,
  listeners: [],
  status: () => ({ active: true, scope: "settingsAndDownloads" }),
  snapshot() {
    return JSON.stringify({ rev: this.rev, data: { settings: this.settings, downloads: [] } });
  },
  dispatch(json, sinceRev) {
    const parsed = JSON.parse(json);
    const commands = [].concat(parsed.commands ?? parsed);
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
  addListener: () => ({ remove() {} }),
};
globalThis.acTestNativeModules = { SolaraStoreAdapter: replicaFake };

const { S, settle, reset, onAndSynced, appMac, files, useBrowser } = await import("./harness.mjs");
const settingsModule = await import("../../store/settings.ts");
const nativeStore = await import("../../store/nativeStore.ts");

test("D11c: with the native store owning settings, sync's own write echoed back isn't republished as this Mac's, and a real change here is", async () => {
  reset();
  replicaFake.choose = settingsModule.choose;
  replicaFake.settings = S().settings;
  assert.ok(nativeStore.startNativeStore().active, "control: the native store fake is active");
  nativeStore.attachReplica(useBrowser);
  const engine = await onAndSynced();
  const b = appMac("set:");
  await b.sync();
  b.store.set("set:appearance", { v: "dark" });
  await b.sync();
  await engine.syncNow();
  await engine.syncNow();
  await settle();
  assert.equal(S().settings.appearance, "dark", "control: this Mac took B's choice");
  const fromHere = () => files().filter(({ scope, file }) => scope === "app" && file.device !== "appMac").flatMap(({ file }) => file.ops ?? []).filter((op) => op.k === "set:appearance");
  assert.deepEqual(fromHere(), [], "the echo isn't sent back as this Mac's choice");
  S().updateSettings({ appearance: "light" });
  await engine.syncNow();
  await settle();
  await b.sync();
  assert.deepEqual(b.store.get("set:appearance"), { v: "light" }, "a real change here reaches B");
});

import assert from "node:assert/strict";
import { test } from "node:test";
const { fixedBy } = await import("./switchOn.mjs");
const SRC = new URL("../..", import.meta.url).href;

const fake = {
  rev: 0,
  held: false,
  status: () => ({ active: true, scope: "everything" }),
  snapshot() { return JSON.stringify({ rev: this.rev, data: {} }); },
  dispatch(json) {
    const parsed = JSON.parse(json);
    const token = !Array.isArray(parsed) && !!parsed.fromSync;
    const commands = [].concat(parsed.commands ?? parsed);
    if (token && this.held && commands.some((c) => c.name === "applyState")) return JSON.stringify({ rev: this.rev, patches: [], busy: true });
    return JSON.stringify({ rev: this.rev, patches: [] });
  },
  catchUp: () => null, flush: () => true, freeze: () => true, useSyncOrigins: () => true,
  addListener: () => ({ remove() {} }),
};
globalThis.acTestNativeModules = { ...globalThis.acTestNativeModules, SolaraStoreAdapter: fake };

const { useBrowser } = await import(`${SRC}/store/browser.ts`);
const nativeStore = await import(`${SRC}/store/nativeStore.ts`);
const { fromSync } = await import(`${SRC}/store/pinOrderChoices.ts`);

test("WRITE-transient: a busy sync write's JS-only keys are never seen by subscribers", fixedBy("step 5"), () => {
  assert.ok(nativeStore.startNativeStore().active);
  assert.ok(nativeStore.nativeOwnsWorkspace(), "control: the fake owns the workspace");
  const seen = [];
  const stop = useBrowser.subscribe((s) => { if (s.live?.["t-sync"]) seen.push("sync's live"); });
  fake.held = true;
  try {
    assert.throws(() => fromSync(() => nativeStore.writeState(useBrowser, { live: { ...useBrowser.getState().live, "t-sync": { loading: true } }, tabs: { ...useBrowser.getState().tabs, "t-sync": { id: "t-sync" } } })), nativeStore.NativeStoreBusy);
    assert.equal(useBrowser.getState().live["t-sync"], undefined, "control: never applied");
    assert.deepEqual(seen, [], "no subscriber acted on sync's live while its tabs bounced");
  } finally {
    fake.held = false;
    stop();
  }
});

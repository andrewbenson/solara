import assert from "node:assert/strict";
import { test } from "node:test";
import { fixedBy } from "./switchOn.mjs";

const fake = {
  rev: 0,
  held: false,
  status: () => ({ active: true, scope: "everything" }),
  snapshot() {
    return JSON.stringify({ rev: this.rev, data: {} });
  },
  dispatch(json) {
    const parsed = JSON.parse(json);
    const token = !Array.isArray(parsed) && !!parsed.fromSync;
    const commands = [].concat(parsed.commands ?? parsed);
    if (token && this.held && commands.some((c) => c.name === "applyState")) return JSON.stringify({ rev: this.rev, patches: [], busy: true });
    for (const { name } of commands) {
      if (name === "beginTransaction") this.held = true;
      if (name === "endTransaction") this.held = false;
    }
    return JSON.stringify({ rev: this.rev, patches: [] });
  },
  catchUp: () => null,
  flush: () => true,
  freeze: () => true,
  useSyncOrigins: () => true,
  addListener: () => ({ remove() {} }),
};
globalThis.acTestNativeModules = { ...globalThis.acTestNativeModules, SolaraStoreAdapter: fake };

const { useBrowser } = await import("../../store/browser.ts");
const nativeStore = await import("../../store/nativeStore.ts");
const { fromSync } = await import("../../store/pinOrderChoices.ts");

test("WRITE-busy: a sync write whose owned slices come back busy, after a user transaction began inside its window, never applies its JS-only keys", fixedBy("step 5"), () => {
  assert.ok(nativeStore.startNativeStore().active, "control: the native store fake owns the workspace");
  assert.ok(nativeStore.nativeOwnsWorkspace());
  const liveBefore = useBrowser.getState().live;
  const tabs = { ...useBrowser.getState().tabs };
  const seen = [];
  const stopWatching = useBrowser.subscribe((s) => seen.push(s.live));
  fake.held = true;
  try {
    assert.throws(() => fromSync(() => nativeStore.writeState(useBrowser, { live: { "t-sync": { loading: true } }, tabs: { ...tabs, "t-sync": { id: "t-sync" } } })), nativeStore.NativeStoreBusy);
    assert.equal(useBrowser.getState().live, liveBefore, "the JS-only live map is untouched when the owned slices bounce");
    assert.ok(seen.every((live) => live === liveBefore), "no subscriber ever saw sync's live map");
  } finally {
    stopWatching();
    fake.held = false;
  }
});

test("WRITE-order: when the native write goes through, the JS-only keys land after it, so they never point at state the native store doesn't have yet", fixedBy("step 5"), () => {
  assert.ok(nativeStore.startNativeStore().active);
  const order = [];
  const dispatch = fake.dispatch;
  fake.dispatch = function (json) {
    const parsed = JSON.parse(json);
    order.push(...[].concat(parsed.commands ?? parsed).map((c) => c.name));
    return dispatch.call(this, json);
  };
  const stopWatching = useBrowser.subscribe((s, prev) => s.live !== prev.live && order.push("live"));
  try {
    fromSync(() => nativeStore.writeState(useBrowser, { live: { "t-later": { loading: true } }, tabs: { ...useBrowser.getState().tabs, "t-later": { id: "t-later" } } }));
    assert.ok(order.indexOf("live") > order.indexOf("applyState"), `live lands after the native write (${order.join(", ")})`);
  } finally {
    stopWatching();
    fake.dispatch = dispatch;
  }
});

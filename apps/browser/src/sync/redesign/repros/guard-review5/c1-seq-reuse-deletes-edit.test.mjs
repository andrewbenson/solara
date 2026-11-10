import "../../../../../../../native/SolaraKit/Scripts/legacy-bookmark-harness.mjs";
import assert from "node:assert/strict";
import { test } from "node:test";
import "../../switchOn.mjs";
const { reset, onAndSynced, shell, S, settle, launch, native, files, sync, rawTransport, titles } = await import('./harness.mjs');

const realNow = Date.now;

function peer(scope) {
  const store = new Map();
  const state = sync.emptyScope();
  state.joined = true;
  const clock = new sync.Clock("peer");
  const adapter = {
    prefix: "bm:",
    extract: () => ({ values: new Map(store) }),
    apply: (visible, changed) => {
      for (const k of changed) visible.has(k) ? store.set(k, visible.get(k)) : store.delete(k);
    },
  };
  return {
    store,
    state,
    sync: () => sync.syncScope({ scope, state, transport: rawTransport, adapters: [adapter], clock, device: "peer" }),
    compact: () => sync.compact(state, rawTransport, scope, "peer", Date.now(), { pruneGrace: 0 }, true),
  };
}

async function scenario(minutes) {
  reset();
  const engine = await onAndSynced();
  const syncId = engine.useSync.getState().profiles.default.syncId;
  const scope = `p:${syncId}`;
  const older = new Map(shell.docs);
  const before = new Set(files().map((f) => f.payload));
  S().addBookmark({ profileId: "default", url: "https://two.example/", title: "Two" });
  await engine.syncNow();
  await settle();
  const b = peer(scope);
  await b.sync();
  assert.deepEqual([...b.store.values()].map((v) => v.t).sort(), ["One", "Two"], "control: the peer has this Mac's batch with Two");
  const hidden = new Set(files().filter((f) => !before.has(f.payload) && f.scope === scope && f.file.kind === "log").map((f) => f.payload));
  const realRead = native.read;
  native.read = async (...args) => {
    const listing = await realRead(...args);
    const stuck = listing.files.filter((f) => hidden.has(f.payload));
    return { ...listing, files: listing.files.filter((f) => !hidden.has(f.payload)), pending: [...listing.pending, ...stuck.map((f) => f.id)] };
  };
  try {
    shell.docs.clear();
    for (const [name, contents] of older) shell.docs.set(name, contents);
    const again = await launch();
    again.startSync();
    await settle();
    await again.syncNow();
    await settle();
    Date.now = () => realNow() + minutes * 60_000;
    S().addBookmark({ profileId: "default", url: "https://three.example/", title: "Three" });
    await again.syncNow();
    await again.syncNow();
    await settle();
    assert.ok(titles().includes("Three"), "control: Three is here after it was published");
    await b.sync();
    await b.compact();
    native.read = realRead;
    await again.syncNow();
    await again.syncNow();
    await settle();
    await b.sync();
    return { here: titles(), there: [...b.store.values()].map((v) => v.t).sort() };
  } finally {
    native.read = realRead;
    Date.now = realNow;
  }
}

test("C1: after a reused seq and a peer's compaction, the bookmark the user added after the rollback is deleted on this Mac too", { todo: "step 7" }, async () => {
  const { here, there } = await scenario(11);
  assert.deepEqual(here, ["One", "Three", "Two"], "the bookmark added here after the rollback is still here");
  assert.deepEqual(there, ["One", "Three", "Two"], "and reached the peer");
});

test("C1-control: the same with the own batch arriving within the wait keeps Three on both", async () => {
  const { here, there } = await scenario(5);
  assert.deepEqual(here, ["One", "Three", "Two"]);
  assert.deepEqual(there, ["One", "Three", "Two"]);
});

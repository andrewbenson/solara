import "../../../../../../../native/SolaraKit/Scripts/legacy-bookmark-harness.mjs";
import assert from "node:assert/strict";
import { test } from "node:test";
const { fixedBy } = await import('../../switchOn.mjs');
const { reset, onAndSynced, S, shell, settle, launch, native, sync, rawTransport, realSetTimeout, files } = await import('./harness.mjs');
const { sealedState } = await import('../../../sealedState.mjs');

function passwordMac(scope) {
  const store = new Map();
  const state = sync.emptyScope();
  state.joined = true;
  const clock = new sync.Clock("pwMac");
  const adapter = {
    prefix: "pw:",
    extract: () => ({ values: new Map(store) }),
    apply: (visible, changed) => {
      for (const k of changed) visible.has(k) ? store.set(k, visible.get(k)) : store.delete(k);
    },
  };
  return { store, sync: () => sync.syncScope({ scope, state, transport: rawTransport, adapters: [adapter], clock, device: "pwMac" }) };
}

async function scenario(rolledBack, ownWriteAfterBackup = false) {
  reset();
  const here = new Map();
  shell.passwordStores.set(null, here);
  const realRead = native.readPasswords;
  native.readPasswords = async () => [...here.values()];
  const timers = [];
  const realST = globalThis.setTimeout;
  globalThis.setTimeout = (fn, ms) => {
    if (ms === 250) return realSetTimeout(fn, 0);
    timers.push({ fn, ms });
    return 0;
  };
  const realNow = Date.now;
  let t = 0;
  const tick = () => {
    t += 1;
    Date.now = () => realNow() + t * 60_000;
  };
  const login = "https://site.example\nme";
  const key = `pw:${login}`;
  here.set(login, { origin: "https://site.example/", url: "https://site.example", username: "me", password: "p1", created: realNow() - 86_400_000 });
  try {
    const engine = await onAndSynced();
    const syncId = engine.useSync.getState().profiles.default.syncId;
    const b = passwordMac(`p:${syncId}`);
    await b.sync();
    assert.equal(b.store.get(key)?.p, "p1", "control: B has this Mac's p1");
    const backup = new Map(shell.docs);
    b.store.set(key, { o: "https://site.example", u: "me", p: "p3" });
    await b.sync();
    tick();
    await engine.syncNow();
    await settle(60);
    assert.equal(here.get(login)?.password, "p3", "control: this Mac took B's p3");
    if (ownWriteAfterBackup) {
      S().addBookmark({ profileId: "default", url: "https://two.example/", title: "Two" });
      tick();
      await engine.syncNow();
      await settle(60);
    }
    const mine = () => files().filter((f) => f.scope === `p:${syncId}` && f.file.kind === "log" && f.file.device !== "pwMac" && (f.file.ops ?? []).some((op) => op.k === key)).length;
    const before = mine();
    tick();
    b.store.set(key, { o: "https://site.example", u: "me", p: "p2" });
    await b.sync();
    if (rolledBack) {
      shell.docs.clear();
      for (const [name, contents] of backup) shell.docs.set(name, contents);
    }
    tick();
    timers.length = 0;
    const again = await launch();
    again.startSync();
    await settle(60);
    let rebuilding = false;
    for (let i = 0; i < 3; i++) {
      tick();
      await again.syncNow();
      await settle(60);
      if (i === 0) rebuilding = !!sealedState(shell.docs)[`p:${syncId}`].rebuild;
    }
    await b.sync();
    if (process.env.DUMP) console.log("OPS", JSON.stringify(files().flatMap(({ file }) => (file.ops ?? []).filter((op) => op.k === key).map((op) => [file.device, file.seq, op.h, op.v?.p]))));
    return { rebuilding, there: b.store.get(key)?.p, mine: here.get(login)?.password, resent: mine() - before };
  } finally {
    Date.now = realNow;
    globalThis.setTimeout = realST;
    native.readPasswords = realRead;
  }
}

test("P1: a rolled-back state whose base still holds an older password than the keychain treats B's newer password as a local conflict, marks it applied without writing it, then resends its own older copy over it", fixedBy("step 3"), async () => {
  const { there, mine, resent, rebuilding } = await scenario(true);
  assert.ok(!rebuilding, "control: nothing told this Mac its state was behind (no rebuild)");
  assert.equal(there, "p2", `B's newer password survives (B has ${there}; this Mac sent ${resent} batch(es) carrying the key)`);
  assert.equal(mine, "p2", `this Mac takes p2 (has ${mine})`);
});

test("P1-control: the same relaunch with the state not rolled back takes B's p2", async () => {
  const { there, mine } = await scenario(false);
  assert.equal(there, "p2");
  assert.equal(mine, "p2");
});

test("P1b: the same with an own batch written after the backup, so the rollback is detected and the scope rebuilds", fixedBy("step 3"), async () => {
  const { there, mine, resent, rebuilding } = await scenario(true, true);
  assert.ok(rebuilding, "control: the relaunch found the state behind its own seqs and opened a rebuild");
  assert.equal(there, "p2", `B's newer password survives (B has ${there}; this Mac sent ${resent} batch(es) carrying the key)`);
  assert.equal(mine, "p2", `this Mac takes p2 (has ${mine})`);
});

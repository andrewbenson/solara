import "../../../../../native/SolaraKit/Scripts/legacy-bookmark-harness.mjs";
import assert from "node:assert/strict";
import { test } from "node:test";
const { fixedBy } = await import('./switchOn.mjs');
const { reset, onAndSynced, S, shell, settle, launch, native, sync, rawTransport, realSetTimeout, files } = await import('./harness.mjs');
const { sealedState } = await import('../sealedState.mjs');

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

async function scenario(applied, editAfterRelaunch = false, later = "p2") {
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
    for (const p of applied) {
      b.store.set(key, { o: "https://site.example", u: "me", p });
      await b.sync();
      tick();
      await engine.syncNow();
      await settle(60);
      assert.equal(here.get(login)?.password, p, `control: this Mac took B's ${p}`);
    }
    const mine = () => files().filter((f) => f.scope === `p:${syncId}` && f.file.kind === "log" && f.file.device !== "pwMac" && (f.file.ops ?? []).some((op) => op.k === key)).length;
    const before = mine();
    tick();
    if (later) {
      b.store.set(key, { o: "https://site.example", u: "me", p: later });
      await b.sync();
    }
    {
      shell.docs.clear();
      for (const [name, contents] of backup) shell.docs.set(name, contents);
    }
    tick();
    timers.length = 0;
    const again = await launch();
    again.startSync();
    await settle(60);
    if (editAfterRelaunch) {
      tick();
      here.set(login, { ...here.get(login), password: "p9", modified: Date.now() });
    }
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


test("AUDIT-pw-docs-two-writes: all of shell.docs rolled back two ledger writes behind Login Data (row at L + 2): sync's applied p4 isn't claimed over B's newer p2", fixedBy("step 3"), async () => {
  const { there, mine, resent } = await scenario(["p3", "p4"]);
  assert.equal(there, "p2", `B's newer password survives (B has ${there}; this Mac sent ${resent} batch(es) carrying the key)`);
  assert.equal(mine, "p2", `this Mac takes p2 (has ${mine})`);
});

test("AUDIT-pw-docs-user-edit: after the same rollback, a password the user changes after sync's last write is published", async () => {
  const { there, mine } = await scenario(["p3", "p4"], true);
  assert.equal(mine, "p9", `control: the user's p9 is here (has ${mine})`);
  assert.equal(there, "p9", `B takes the user's p9 (B has ${there})`);
});

test("AUDIT-pw-equal-record: after the rollback, a login equal to its current record (p3 applied by sync, nothing newer on B) is no edit and isn't published again", async () => {
  const { there, mine, resent } = await scenario(["p3"], false, null);
  assert.equal(mine, "p3", "control: this Mac still has p3");
  assert.equal(there, "p3");
  assert.equal(resent, 0, `nothing is published for it (${resent} batch(es) carried it)`);
});

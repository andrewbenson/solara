import "../../../../../native/SolaraKit/Scripts/legacy-bookmark-harness.mjs";
import assert from "node:assert/strict";
import { test } from "node:test";
const { fixedBy } = await import('./switchOn.mjs');
const { shell, settle, reset, onAndSynced, passwordMac, native, realReadPasswords, realSetTimeout } = await import('./harness.mjs');

const SITE = "https://site.example";
const loginKey = (user) => `${SITE}\n${user}`;
const syncKey = (user) => `pw:${loginKey(user)}`;
const login = (user, password, modified) => ({ origin: `${SITE}/`, url: `${SITE}/`, username: user, password, created: modified, modified });

async function massChange(run) {
  reset();
  const here = new Map();
  shell.passwordStores.set(null, here);
  native.readPasswords = async () => [...here.values()];
  const realST = globalThis.setTimeout;
  const realNow = Date.now;
  let offset = 0;
  globalThis.setTimeout = (fn, ms) => (ms === 250 ? realSetTimeout(fn, 0) : 0);
  Date.now = () => realNow() + offset;
  const cycles = async (engine, n = 3) => {
    for (let i = 0; i < n; i++) {
      offset += 60_000;
      await engine.syncNow();
      await settle(60);
    }
  };
  try {
    for (let i = 0; i < 10; i++) here.set(loginKey(`u${i}`), login(`u${i}`, `p${i}`, Date.now()));
    const engine = await onAndSynced();
    const syncId = engine.useSync.getState().profiles.default.syncId;
    const b = passwordMac(`p:${syncId}`);
    await b.sync();
    offset += 3_600_000;
    for (let i = 0; i < 8; i++) here.set(loginKey(`u${i}`), login(`u${i}`, `changed${i}`, Date.now()));
    await cycles(engine);
    await b.sync();
    await run({ engine, b, here, cycles });
  } finally {
    Date.now = realNow;
    globalThis.setTimeout = realST;
    native.readPasswords = realReadPasswords;
  }
}

const changedOn = (store) => [...store.values()].filter((v) => v.p.startsWith("changed")).length;

test("HELD-shown: the Sync pane learns how many password changes are held for this profile", fixedBy("step 3b"), () =>
  massChange(async ({ engine, b }) => {
    assert.equal(changedOn(b.store), 0, "control: nothing went out");
    assert.equal(engine.useSync.getState().heldPasswords?.default, 8);
  }));

test("HELD-restore: restoring puts the folder's passwords back here and sends nothing", fixedBy("step 3b"), () =>
  massChange(async ({ engine, b, here, cycles }) => {
    engine.resolveHeldPasswords("default", "restore");
    await cycles(engine);
    await b.sync();
    assert.equal(changedOn(b.store), 0, "B keeps its passwords");
    assert.deepEqual([...here.values()].filter((l) => l.password.startsWith("changed")).map((l) => l.username), [], "this Mac has them back");
    assert.equal(engine.useSync.getState().heldPasswords?.default ?? 0, 0, "and nothing is held any more");
  }));

test("HELD-confirm: confirming sends the held changes to the other Macs", fixedBy("step 3b"), () =>
  massChange(async ({ engine, b, cycles }) => {
    engine.resolveHeldPasswords("default", "confirm");
    await cycles(engine);
    await b.sync();
    assert.equal(changedOn(b.store), 8, "B gets all eight");
    assert.equal(engine.useSync.getState().heldPasswords?.default ?? 0, 0);
  }));

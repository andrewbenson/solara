import "../../../../../../native/SolaraKit/Scripts/legacy-bookmark-harness.mjs";
import assert from "node:assert/strict";
import { test } from "node:test";
const { fixedBy } = await import('../switchOn.mjs');
const { world, onAndSynced, passwordMac, loginKey, syncKey, login, SITE, loginDataMark, launch, settle } = await import('./world.mjs');

async function restoredLoginData(w) {
  for (let i = 0; i < 40; i++) w.here.set(loginKey(`old${i}`), login(`old${i}`, `p${i}`, Date.now()));
  const engine = await onAndSynced();
  const syncId = engine.useSync.getState().profiles.default.syncId;
  const b = passwordMac(`p:${syncId}`);
  await b.sync();
  const backup = new Map([...w.here].map(([k, v]) => [k, { ...v }]));
  const markInBackup = loginDataMark.value;
  for (let i = 0; i < 30; i++) b.store.set(syncKey(`new${i}`), { o: SITE, u: `new${i}`, p: `n${i}` });
  await b.sync();
  await w.cycles(engine);
  assert.equal(w.here.size, 70, "control: this Mac applied B's 30 logins");
  w.here.clear();
  for (const [k, v] of backup) w.here.set(k, v);
  loginDataMark.value = markInBackup;
  return { engine, b };
}

test("REBUILD-then-unconfirmed: a rebuild whose re-apply doesn't land deletes the missing logins everywhere on the next read", fixedBy("step 3"), () =>
  world(async (w) => {
    const { engine, b } = await restoredLoginData(w);
    const realSet = w.here.set;
    w.here.set = function (k, v) {
      return k.includes("new") ? this : realSet.call(this, k, v);
    };
    await w.cycles(engine, 1);
    w.here.set = realSet;
    assert.equal(w.here.size, 40, "control: Chrome didn't take the re-applied logins this time");
    w.later(5);
    await w.cycles(engine, 3);
    await b.sync();
    assert.equal(b.store.size, 70, `B keeps all 70 (B has ${b.store.size})`);
  }));

test("REBUILD-then-relaunch: quitting right after a rebuild's read, before its apply, deletes the missing logins everywhere at the next launch", fixedBy("step 3"), () =>
  world(async (w) => {
    const { engine, b } = await restoredLoginData(w);
    const realSet = w.here.set;
    w.here.set = function (k, v) {
      return k.includes("new") ? this : realSet.call(this, k, v);
    };
    w.readable = true;
    await w.cycles(engine, 1);
    w.here.set = realSet;
    for (const k of [...w.here.keys()]) if (k.includes("new")) w.here.delete(k);
    const again = await launch();
    again.startSync();
    await settle(60);
    w.later(5);
    await w.cycles(again, 3);
    await b.sync();
    assert.equal(b.store.size, 70, `B keeps all 70 (B has ${b.store.size})`);
  }));

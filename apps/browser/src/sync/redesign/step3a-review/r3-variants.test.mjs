import "../../../../../../native/SolaraKit/Scripts/legacy-bookmark-harness.mjs";
import assert from "node:assert/strict";
import { test } from "node:test";
const { fixedBy } = await import('../switchOn.mjs');
const { world, onAndSynced, passwordMac, loginKey, syncKey, login, SITE, launch, settle, loginDataMark, shell } = await import('./world.mjs');

async function held(w, n, del, extra = 0) {
  for (let i = 0; i < n; i++) w.here.set(loginKey(`u${i}`), login(`u${i}`, `p${i}`, Date.now()));
  const engine = await onAndSynced();
  const syncId = engine.useSync.getState().profiles.default.syncId;
  const b = passwordMac(`p:${syncId}`);
  await b.sync();
  w.later(60);
  for (let i = 0; i < del; i++) w.here.delete(loginKey(`u${i}`));
  await w.cycles(engine);
  await b.sync();
  assert.equal(b.store.size, n, "control: the deletions are held");
  return { engine, b, syncId };
}

test("V-hold-relaunch: a held mass deletion stays held across a relaunch while B adds logins", fixedBy("step 3"), () =>
  world(async (w) => {
    const { b } = await held(w, 10, 6);
    const again = await launch();
    again.startSync();
    await settle(60);
    for (let i = 0; i < 4; i++) b.store.set(syncKey(`b${i}`), { o: SITE, u: `b${i}`, p: `q${i}` });
    await b.sync();
    await w.cycles(again, 4);
    await b.sync();
    assert.equal([...Array(6).keys()].filter((i) => !b.store.has(syncKey(`u${i}`))).length, 0, "nothing held went out");
    assert.equal(again.useSync.getState().heldPasswords?.default, 6, "and the prompt is still there after the relaunch");
  }));

test("V-hold-relaunch-confirm: confirming, then quitting before the next cycle, still sends the changes or asks again", fixedBy("step 3"), () =>
  world(async (w) => {
    const { engine, b } = await held(w, 10, 6);
    engine.resolveHeldPasswords("default", "confirm");
    const again = await launch();
    again.startSync();
    await settle(60);
    await w.cycles(again, 3);
    await b.sync();
    const gone = [...Array(6).keys()].filter((i) => !b.store.has(syncKey(`u${i}`))).length;
    const asked = again.useSync.getState().heldPasswords?.default ?? 0;
    assert.ok(gone === 6 || asked === 6, `either all 6 go out or the prompt comes back (gone ${gone}, held ${asked})`);
  }));

test("V-confirm-exemption: a confirmed key that never went out isn't exempt from a later hold", fixedBy("step 3"), () =>
  world(async (w) => {
    const { engine, b } = await held(w, 20, 11);
    b.store.set(syncKey("u0"), { o: SITE, u: "u0", p: "edited on B" });
    await b.sync();
    engine.resolveHeldPasswords("default", "confirm");
    await w.cycles(engine, 3);
    await b.sync();
    assert.equal(w.here.get(loginKey("u0"))?.password, "edited on B", "control: the conflicting deletion was dropped and B's edit applied");
    assert.equal(b.store.size, 10, "control: the other 10 deletions went out");
    w.later(60);
    for (const u of ["u0", "u11", "u12", "u13", "u14", "u15"]) w.here.delete(loginKey(u));
    await w.cycles(engine, 3);
    await b.sync();
    assert.equal(b.store.size, 10, `a new mass deletion of 6 of 10 is held (B has ${b.store.size})`);
  }));

test("V-restore-race: an edit made right after choosing Restore, before the next read, isn't overwritten", fixedBy("step 3"), () =>
  world(async (w) => {
    const { engine, b } = await held(w, 10, 6);
    w.readable = false;
    engine.resolveHeldPasswords("default", "restore");
    await settle(60);
    w.later(1);
    w.here.set(loginKey("u0"), login("u0", "typed after restore", Date.now()));
    w.readable = true;
    await w.cycles(engine, 3);
    await b.sync();
    assert.equal(w.here.get(loginKey("u0"))?.password, "typed after restore", `the new edit is kept here (has ${w.here.get(loginKey("u0"))?.password})`);
  }));

test("V-rebuild-while-held: Login Data restore while 6 deletions are held doesn't answer the prompt by itself", fixedBy("step 3"), () =>
  world(async (w) => {
    const { engine, b } = await held(w, 10, 6);
    loginDataMark.value = null;
    await w.cycles(engine, 3);
    await b.sync();
    const asked = engine.useSync.getState().heldPasswords?.default ?? 0;
    const back = [...Array(6).keys()].filter((i) => w.here.has(loginKey(`u${i}`))).length;
    assert.ok(asked === 6 || back === 0, `the rebuild silently restored ${back} held deletions (held now ${asked})`);
  }));

test("V-rebuild-unconfirmed-relaunch-twice: a rebuild, an unconfirmed apply, two relaunches: nothing is deleted on B", fixedBy("step 3"), () =>
  world(async (w) => {
    for (let i = 0; i < 40; i++) w.here.set(loginKey(`old${i}`), login(`old${i}`, `p${i}`, Date.now()));
    let engine = await onAndSynced();
    const syncId = engine.useSync.getState().profiles.default.syncId;
    const b = passwordMac(`p:${syncId}`);
    await b.sync();
    const backup = new Map([...w.here].map(([k, v]) => [k, { ...v }]));
    const markInBackup = loginDataMark.value;
    for (let i = 0; i < 12; i++) b.store.set(syncKey(`new${i}`), { o: SITE, u: `new${i}`, p: `n${i}` });
    await b.sync();
    await w.cycles(engine);
    w.here.clear();
    for (const [k, v] of backup) w.here.set(k, v);
    loginDataMark.value = markInBackup;
    const realSet = w.here.set;
    w.here.set = function (k, v) { return k.includes("new") ? this : realSet.call(this, k, v); };
    await w.cycles(engine, 1);
    for (let r = 0; r < 2; r++) {
      engine = await launch();
      engine.startSync();
      await settle(60);
      await w.cycles(engine, 2);
    }
    w.here.set = realSet;
    await w.cycles(engine, 3);
    await b.sync();
    assert.equal(b.store.size, 52, `B keeps all 52 (B has ${b.store.size})`);
    assert.equal(w.here.size, 52, "and this Mac gets the 12 back once Chrome takes them");
  }));

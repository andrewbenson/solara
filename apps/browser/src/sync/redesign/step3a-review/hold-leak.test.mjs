import "../../../../../../native/SolaraKit/Scripts/legacy-bookmark-harness.mjs";
import assert from "node:assert/strict";
import { test } from "node:test";
const { fixedBy } = await import('../switchOn.mjs');
const { world, onAndSynced, passwordMac, loginKey, syncKey, login, SITE } = await import('./world.mjs');

test("HOLD-leak: held mass deletions go out once B adds a few logins and the ledger grows", fixedBy("step 3b"), () =>
  world(async (w) => {
    for (let i = 0; i < 10; i++) w.here.set(loginKey(`u${i}`), login(`u${i}`, `p${i}`, Date.now()));
    const engine = await onAndSynced();
    const syncId = engine.useSync.getState().profiles.default.syncId;
    const b = passwordMac(`p:${syncId}`);
    await b.sync();
    assert.equal(b.store.size, 10, "control: B has all 10");
    w.later(60);
    for (let i = 0; i < 6; i++) w.here.delete(loginKey(`u${i}`));
    await w.cycles(engine);
    await b.sync();
    assert.equal(b.store.size, 10, "control: the 6 deletions are held");
    for (let i = 0; i < 3; i++) b.store.set(syncKey(`b${i}`), { o: SITE, u: `b${i}`, p: `q${i}` });
    await b.sync();
    await w.cycles(engine, 4);
    await b.sync();
    const gone = [...Array(6).keys()].filter((i) => !b.store.has(syncKey(`u${i}`)));
    assert.deepEqual(gone, [], `held deletions stay held until the user confirms (B lost u${gone.join(", u")})`);
  }));

test("HOLD-leak-additions: held mass edits go out after the user saves a few new logins", fixedBy("step 3b"), () =>
  world(async (w) => {
    for (let i = 0; i < 10; i++) w.here.set(loginKey(`u${i}`), login(`u${i}`, `p${i}`, Date.now()));
    const engine = await onAndSynced();
    const syncId = engine.useSync.getState().profiles.default.syncId;
    const b = passwordMac(`p:${syncId}`);
    await b.sync();
    w.later(60);
    for (let i = 0; i < 6; i++) w.here.set(loginKey(`u${i}`), login(`u${i}`, `changed${i}`, Date.now()));
    for (let i = 0; i < 3; i++) w.here.set(loginKey(`n${i}`), login(`n${i}`, `new${i}`, Date.now()));
    await w.cycles(engine, 4);
    await b.sync();
    const changed = [...b.store.values()].filter((v) => v.p.startsWith("changed")).length;
    assert.equal(changed, 0, `held changes don't reach B before the user confirms (B has ${changed} changed)`);
  }));

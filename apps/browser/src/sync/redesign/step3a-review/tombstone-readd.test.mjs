import "../../../../../../native/SolaraKit/Scripts/legacy-bookmark-harness.mjs";
import assert from "node:assert/strict";
import { test } from "node:test";
const { world, onAndSynced, passwordMac, loginKey, syncKey, login } = await import('./world.mjs');

test("READD: a login saved again right after B deleted it is published, even with B's clock 10 minutes ahead", () =>
  world(async (w) => {
    w.here.set(loginKey("me"), login("me", "v1", Date.now()));
    const engine = await onAndSynced();
    await w.cycles(engine);
    const syncId = engine.useSync.getState().profiles.default.syncId;
    const b = passwordMac(`p:${syncId}`);
    await b.sync();
    w.later(10);
    b.store.delete(syncKey("me"));
    await b.sync();
    w.later(-10);
    await w.cycles(engine);
    assert.ok(!w.here.has(loginKey("me")), "control: this Mac applied the deletion");
    w.here.set(loginKey("me"), login("me", "v2", Date.now()));
    await w.cycles(engine);
    await b.sync();
    assert.equal(b.store.get(syncKey("me"))?.p, "v2", `the re-saved login reaches B (B has ${JSON.stringify(b.store.get(syncKey("me")))})`);
  }));

test("FUTURE: a login Chrome stamped a day ahead, then reverted on purpose after the clock is fixed, is published", () =>
  world(async (w) => {
    w.here.set(loginKey("me"), login("me", "v1", Date.now()));
    const engine = await onAndSynced();
    await w.cycles(engine);
    const syncId = engine.useSync.getState().profiles.default.syncId;
    const b = passwordMac(`p:${syncId}`);
    await b.sync();
    w.here.set(loginKey("me"), login("me", "v2", Date.now() + 86_400_000));
    await w.cycles(engine);
    await b.sync();
    assert.equal(b.store.get(syncKey("me"))?.p, "v2", "control: v2 went out");
    w.later(60);
    w.here.set(loginKey("me"), login("me", "v1", Date.now()));
    await w.cycles(engine);
    await b.sync();
    assert.equal(b.store.get(syncKey("me"))?.p, "v1", `the deliberate revert goes out (B has ${b.store.get(syncKey("me"))?.p}; this Mac has ${w.here.get(loginKey("me"))?.password})`);
  }));

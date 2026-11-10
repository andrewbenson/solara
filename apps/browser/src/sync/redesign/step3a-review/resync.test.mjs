import "../../../../../../native/SolaraKit/Scripts/legacy-bookmark-harness.mjs";
import assert from "node:assert/strict";
import { test } from "node:test";
const { fixedBy } = await import('../switchOn.mjs');
const { world, onAndSynced, passwordMac, loginKey, syncKey, login, shell, LEDGER, folder, SITE } = await import('./world.mjs');

for (const how of ["applied from B", "edited here"]) {
  test(`RESYNC (${how}): a login is published to a new folder when sync is turned back on`, fixedBy("step 3"), () =>
    world(async (w) => {
      w.here.set(loginKey("mine"), login("mine", "v1", Date.now()));
      const engine = await onAndSynced();
      await w.cycles(engine);
      const first = engine.useSync.getState().profiles.default.syncId;
      const b0 = passwordMac(`p:${first}`);
      await b0.sync();
      if (how === "applied from B") {
        b0.store.set(syncKey("me"), { o: SITE, u: "me", p: "from B" });
        await b0.sync();
        await w.cycles(engine);
        assert.equal(w.here.get(loginKey("me"))?.password, "from B", "control: this Mac applied B's login");
      } else {
        w.later(5);
        w.here.set(loginKey("me"), login("me", "v1", Date.now()));
        await w.cycles(engine);
        w.later(5);
        w.here.set(loginKey("me"), login("me", "v2", Date.now()));
        await w.cycles(engine);
        await b0.sync();
        assert.equal(b0.store.get(syncKey("me"))?.p, "v2", "control: the edit reached B");
      }
      await engine.stopSync({ deleteData: true });
      folder.clear();
      assert.ok(shell.docs.get(LEDGER), "control: the ledger outlived turning sync off");
      w.later(10);
      const turned = await engine.turnOnSync("/sync-new");
      assert.ok("ok" in turned, JSON.stringify(turned));
      await w.cycles(engine, 4);
      const syncId = engine.useSync.getState().profiles.default.syncId;
      const b = passwordMac(`p:${syncId}`);
      await b.sync();
      assert.ok(b.store.has(syncKey("mine")), "control: the login first published here goes out again");
      assert.ok(b.store.has(syncKey("me")), `the login is published to the new folder (it has ${JSON.stringify([...b.store.keys()])}; ledger ${JSON.stringify(w.ledger()?.keys?.[syncKey("me")])})`);
    }));
}

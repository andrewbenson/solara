import "../../../../../../native/SolaraKit/Scripts/legacy-bookmark-harness.mjs";
import assert from "node:assert/strict";
import { test } from "node:test";
const { fixedBy } = await import('../switchOn.mjs');
const { world, onAndSynced, passwordMac, loginKey, syncKey, login, SITE, shell } = await import('./world.mjs');
const { sealedState } = await import('../../sealedState.mjs');

test("V-failing-save: one login Chrome refuses to save doesn't keep the others unapplied", fixedBy("step 3"), () =>
  world(async (w) => {
    const cef = shell.solaraCoreNativeModules.SolaraCEF;
    const realSave = cef.savePassword;
    const engine = await onAndSynced();
    const syncId = engine.useSync.getState().profiles.default.syncId;
    const b = passwordMac(`p:${syncId}`);
    await b.sync();
    cef.savePassword = async (p, o, u, pw) => (u === "bad" ? { error: "refused" } : realSave(p, o, u, pw));
    try {
      b.store.set(syncKey("bad"), { o: SITE, u: "bad", p: "x" });
      for (let i = 0; i < 3; i++) b.store.set(syncKey(`ok${i}`), { o: SITE, u: `ok${i}`, p: `y${i}` });
      await b.sync();
      await w.cycles(engine, 4);
      const state = sealedState(shell.docs)[`p:${syncId}`];
      const stuck = state.unapplied.filter((k) => k.startsWith("pw:") && !k.endsWith("bad"));
      assert.equal(w.here.size, 3, "control: the three good logins are here");
      assert.deepEqual(stuck, [], `only the refused login stays unapplied (unapplied: ${JSON.stringify(state.unapplied)})`);
      const ledger = JSON.parse(shell.docs.get("sync-pw-ledger.json") ?? "{}").profiles?.[""];
      assert.ok(ledger?.keys?.[syncKey("ok0")], "and the good ones are in the ledger");
    } finally {
      cef.savePassword = realSave;
    }
  }));

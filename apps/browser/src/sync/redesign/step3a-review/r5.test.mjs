import "../../../../../../native/SolaraKit/Scripts/legacy-bookmark-harness.mjs";
import assert from "node:assert/strict";
import { test } from "node:test";
const { fixedBy } = await import('../switchOn.mjs');
const { world, onAndSynced, passwordMac, loginKey, syncKey, login, SITE, native, shell } = await import('./world.mjs');

const gatedAt = () => JSON.parse(shell.docs.get("sync-pw-ledger.json")).profiles[""].gated?.[syncKey("me")];
async function trickle(w, run) {
  w.here.set(loginKey("me"), login("me", "v1", Date.now()));
  const engine = await onAndSynced();
  await w.cycles(engine);
  const syncId = engine.useSync.getState().profiles.default.syncId;
  const b = passwordMac(`p:${syncId}`);
  await b.sync();
  const realRead = native.read;
  const start = Date.now();
  const gaps = new Set();
  native.read = async (f, scope, known) => {
    const listing = await realRead(f, scope, known);
    const minute = Math.floor((Date.now() - start) / 60_000);
    if (gaps.has(minute)) return listing;
    return { ...listing, pending: [...listing.pending, `t-${minute}`, `t-${minute - 1}`] };
  };
  try {
    await run({ engine, b, gaps, start });
  } finally {
    native.read = realRead;
  }
}

for (const how of ["re-saved", "lost to B"]) {
  test(`R5-stale-gated (${how}): a deletion after an earlier one was undone gets a fresh hold`, fixedBy("step 3"), () =>
    world((w) =>
      trickle(w, async ({ engine, b }) => {
        w.here.delete(loginKey("me"));
        await w.cycles(engine, 1);
        assert.ok(gatedAt(), "control: gated");
        await w.cycles(engine, 5);
        if (how === "re-saved") w.here.set(loginKey("me"), login("me", "v1", Date.now() - 3_600_000));
        else {
          b.store.set(syncKey("me"), { o: SITE, u: "me", p: "v2 from B" });
          await b.sync();
        }
        await w.cycles(engine, 2);
        assert.ok(w.here.has(loginKey("me")), "control: the login is back here");
        assert.equal(gatedAt(), undefined, "the old first-gated time is dropped");
        await w.cycles(engine, 3);
        w.here.delete(loginKey("me"));
        await w.cycles(engine, 1);
        await b.sync();
        assert.ok(b.store.has(syncKey("me")), "the new deletion is held, not sent at once on the stale time");
      }),
    ));
}

test("R5-gap: a one-minute gap in the trickle sends the deletion then, not a fresh 10 minutes later", fixedBy("step 3"), () =>
  world((w) =>
    trickle(w, async ({ engine, b, gaps, start }) => {
      w.here.delete(loginKey("me"));
      await w.cycles(engine, 1);
      const minute = Math.floor((Date.now() - start) / 60_000);
      for (const m of [minute + 4, minute + 5]) gaps.add(m);
      let goneAt = null;
      for (let i = 0; i < 9 && goneAt === null; i++) {
        await w.cycles(engine, 1);
        await b.sync();
        if (!b.store.has(syncKey("me"))) goneAt = Math.floor((Date.now() - start) / 60_000);
      }
      assert.ok(goneAt !== null && goneAt <= minute + 7, `out during or right after the gap, or by the limit (minute ${goneAt}, gap at ${minute + 4})`);
    }),
  ));

import "../../../../../../native/SolaraKit/Scripts/legacy-bookmark-harness.mjs";
import assert from "node:assert/strict";
import { test } from "node:test";
const { fixedBy } = await import('../switchOn.mjs');
const { world, onAndSynced, passwordMac, loginKey, syncKey, login, SITE, native, folder } = await import('./world.mjs');

test("PENDING-delete: a deletion noticed while B's newer edit is still downloading doesn't beat that edit", fixedBy("step 3"), () =>
  world(async (w) => {
    w.here.set(loginKey("me"), login("me", "v1", Date.now()));
    const engine = await onAndSynced();
    await w.cycles(engine);
    const syncId = engine.useSync.getState().profiles.default.syncId;
    const b = passwordMac(`p:${syncId}`);
    await b.sync();
    w.readable = false;
    w.here.delete(loginKey("me"));
    await w.cycles(engine, 1);
    w.later(30);
    const before = new Set(folder.keys());
    b.store.set(syncKey("me"), { o: SITE, u: "me", p: "v2 from B" });
    await b.sync();
    const hidden = new Set([...folder.keys()].filter((id) => !before.has(id)));
    const realRead = native.read;
    native.read = async (f, scope, known) => {
      const listing = await realRead(f, scope, known);
      const pending = listing.files.filter((x) => hidden.has(x.id)).map((x) => x.id);
      return { ...listing, files: listing.files.filter((x) => !hidden.has(x.id)), present: listing.present.filter((id) => !hidden.has(id)), pending: [...listing.pending, ...pending] };
    };
    w.later(30);
    w.readable = true;
    await w.cycles(engine, 2);
    native.read = realRead;
    await w.cycles(engine, 3);
    await b.sync();
    assert.equal(b.store.get(syncKey("me"))?.p, "v2 from B", `B's later edit survives (B has ${JSON.stringify(b.store.get(syncKey("me")))})`);
    assert.equal(w.here.get(loginKey("me"))?.password, "v2 from B", "and this Mac takes it");
  }));

test("PENDING-delete control: the same without the download wait", fixedBy("step 3"), () =>
  world(async (w) => {
    w.here.set(loginKey("me"), login("me", "v1", Date.now()));
    const engine = await onAndSynced();
    await w.cycles(engine);
    const syncId = engine.useSync.getState().profiles.default.syncId;
    const b = passwordMac(`p:${syncId}`);
    await b.sync();
    w.readable = false;
    w.here.delete(loginKey("me"));
    await w.cycles(engine, 1);
    w.later(30);
    b.store.set(syncKey("me"), { o: SITE, u: "me", p: "v2 from B" });
    await b.sync();
    w.later(30);
    w.readable = true;
    await w.cycles(engine, 5);
    await b.sync();
    assert.equal(b.store.get(syncKey("me"))?.p, "v2 from B");
  }));

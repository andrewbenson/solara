import "../../../../../../native/SolaraKit/Scripts/legacy-bookmark-harness.mjs";
import assert from "node:assert/strict";
import { test } from "node:test";
const { fixedBy } = await import('../switchOn.mjs');
const { world, onAndSynced, passwordMac, loginKey, syncKey, login, SITE, native, folder, shell, launch, settle } = await import('./world.mjs');

test("UNFORCED-edit: with only timer cycles 15 s apart, an edit here is published within a few cycles", fixedBy("step 3"), () =>
  world(async (w) => {
    w.here.set(loginKey("me"), login("me", "v1", Date.now()));
    const engine = await onAndSynced();
    await w.cycles(engine);
    const syncId = engine.useSync.getState().profiles.default.syncId;
    const b = passwordMac(`p:${syncId}`);
    await b.sync();
    w.later(5);
    w.here.set(loginKey("me"), login("me", "v2 here", Date.now()));
    await w.unforced(6);
    await b.sync();
    assert.equal(b.store.get(syncKey("me"))?.p, "v2 here");
  }));

test("UNFORCED-quiet: a login Chrome never confirms doesn't stop another login's edit from going out on timer cycles", fixedBy("step 3"), () =>
  world(async (w) => {
    w.here.set(loginKey("me"), login("me", "v1", Date.now()));
    w.here.set(loginKey("stuck"), login("stuck", "s1", Date.now()));
    const engine = await onAndSynced();
    await w.cycles(engine);
    const syncId = engine.useSync.getState().profiles.default.syncId;
    const b = passwordMac(`p:${syncId}`);
    await b.sync();
    const stuck = w.here.get(loginKey("stuck"));
    const realSave = shell.passwordStores;
    b.store.set(syncKey("stuck"), { o: SITE, u: "stuck", p: "s2 from B" });
    await b.sync();
    const solara = globalThis.acTestNativeModules?.SolaraCEF;
    const save = solara?.savePassword;
    if (solara) solara.savePassword = async (p, o, u, pw) => (u === "stuck" ? (w.here.set(loginKey("stuck"), stuck), { ok: true }) : save(p, o, u, pw));
    try {
      await w.unforced(3);
      w.later(2);
      w.here.set(loginKey("me"), login("me", "v2 here", Date.now()));
      await w.unforced(10);
      await b.sync();
      assert.equal(b.store.get(syncKey("me"))?.p, "v2 here", "the other edit went out");
    } finally {
      if (solara) solara.savePassword = save;
      void realSave;
    }
  }));

test("GATE-bound: a deletion held by a pending file goes out once the file has been pending past the hold limit", fixedBy("step 3"), () =>
  world(async (w) => {
    w.here.set(loginKey("me"), login("me", "v1", Date.now()));
    const engine = await onAndSynced();
    await w.cycles(engine);
    const syncId = engine.useSync.getState().profiles.default.syncId;
    const b = passwordMac(`p:${syncId}`);
    await b.sync();
    const realRead = native.read;
    native.read = async (f, scope, known) => {
      const listing = await realRead(f, scope, known);
      return { ...listing, pending: [...listing.pending, "never-arrives"] };
    };
    try {
      w.here.delete(loginKey("me"));
      await w.cycles(engine, 2);
      await b.sync();
      assert.ok(b.store.has(syncKey("me")), "control: held while the file is new");
      w.later(11);
      await w.cycles(engine, 2);
      await b.sync();
      assert.equal(b.store.has(syncKey("me")), false, "the deletion goes out once the hold limit passes");
    } finally {
      native.read = realRead;
    }
  }));

test("GATE-bound-trickle: a deletion goes out by the hold limit plus one cycle after it was first gated, while a new file is pending every minute and each takes two", fixedBy("step 3"), () =>
  world(async (w) => {
    w.here.set(loginKey("me"), login("me", "v1", Date.now()));
    const engine = await onAndSynced();
    await w.cycles(engine);
    const syncId = engine.useSync.getState().profiles.default.syncId;
    const b = passwordMac(`p:${syncId}`);
    await b.sync();
    const realRead = native.read;
    const start = Date.now();
    native.read = async (f, scope, known) => {
      const listing = await realRead(f, scope, known);
      const minute = Math.floor((Date.now() - start) / 60_000);
      const downloading = [minute, minute - 1].filter((m) => m >= 0).map((m) => `trickle-${m}`);
      return { ...listing, pending: [...listing.pending, ...downloading] };
    };
    try {
      w.here.delete(loginKey("me"));
      await w.cycles(engine, 1);
      const firstGated = Date.now();
      await b.sync();
      assert.ok(b.store.has(syncKey("me")), "control: the deletion is held while files download");
      let goneAt = null;
      for (let i = 0; i < 16 && goneAt === null; i++) {
        await w.cycles(engine, 1);
        await b.sync();
        if (!b.store.has(syncKey("me"))) goneAt = Date.now();
      }
      assert.ok(goneAt !== null, "the deletion went out while the trickle kept going");
      assert.ok(goneAt - firstGated <= 10 * 60_000 + 60_000, `within the hold limit plus one cycle (${(goneAt - firstGated) / 60_000} min)`);
    } finally {
      native.read = realRead;
    }
  }));

test("GATE-bound-relaunch: a relaunch during the trickle keeps the deletion's first-gated time, so the hold doesn't restart", fixedBy("step 3"), () =>
  world(async (w) => {
    w.here.set(loginKey("me"), login("me", "v1", Date.now()));
    const engine = await onAndSynced();
    await w.cycles(engine);
    const syncId = engine.useSync.getState().profiles.default.syncId;
    const b = passwordMac(`p:${syncId}`);
    await b.sync();
    const realRead = native.read;
    const start = Date.now();
    native.read = async (f, scope, known) => {
      const listing = await realRead(f, scope, known);
      const minute = Math.floor((Date.now() - start) / 60_000);
      const downloading = [minute, minute - 1].filter((m) => m >= 0).map((m) => `trickle-${m}`);
      return { ...listing, pending: [...listing.pending, ...downloading] };
    };
    try {
      w.here.delete(loginKey("me"));
      await w.cycles(engine, 1);
      const firstGated = Date.now();
      await b.sync();
      assert.ok(b.store.has(syncKey("me")), "control: the deletion is held while files download");
      let goneAt = null;
      let live = engine;
      for (let i = 0; i < 16 && goneAt === null; i++) {
        if (i === 5) {
          const gatedAt = () => JSON.parse(shell.docs.get("sync-pw-ledger.json")).profiles[""].gated?.[syncKey("me")];
          const before = gatedAt();
          assert.ok(before, "control: the first-gated time is saved");
          live = await launch();
          live.startSync();
          await settle(60);
          await w.cycles(live, 1);
          assert.equal(gatedAt(), before, "the relaunch keeps it");
          continue;
        }
        await w.cycles(live, 1);
        await b.sync();
        if (!b.store.has(syncKey("me"))) goneAt = Date.now();
      }
      assert.ok(goneAt !== null, "the deletion went out while the trickle kept going");
      assert.ok(goneAt - firstGated <= 20 * 60_000, `within the hold limit plus the old guard's 10-minute fresh-load wait, which step 11 removes (${(goneAt - firstGated) / 60_000} min)`);
    } finally {
      native.read = realRead;
    }
  }));

test("RESYNC-same-id: a rejoin that keeps the profile's sync id still re-judges every login against the new folder", fixedBy("step 3"), () =>
  world(async (w) => {
    w.here.set(loginKey("me"), login("me", "v1", Date.now()));
    const engine = await onAndSynced();
    await w.cycles(engine);
    const first = engine.useSync.getState().profiles.default.syncId;
    const scopeBefore = engine.ledgerScopeOf("default");
    await engine.stopSync({ deleteData: true });
    folder.clear();
    w.later(10);
    assert.ok("ok" in (await engine.turnOnSync("/sync")));
    const saved = JSON.parse(shell.docs.get("sync.json"));
    saved.profiles = { ...saved.profiles, default: { ...saved.profiles?.default, syncId: first, enabled: true } };
    shell.docs.set("sync.json", JSON.stringify(saved));
    const again = await launch();
    again.startSync();
    await settle(60);
    assert.notEqual(again.ledgerScopeOf("default"), scopeBefore, "the ledger's scope changes on every join");
    await w.cycles(again, 4);
    const b = passwordMac(`p:${first}`);
    await b.sync();
    assert.equal(b.store.get(syncKey("me"))?.p, "v1", "the login goes out to the new folder");
  }));

test("GATE-edits-pass: while a file is pending, an edit and an addition here still go out; only a deletion waits", fixedBy("step 3"), () =>
  world(async (w) => {
    w.here.set(loginKey("edit"), login("edit", "e1", Date.now()));
    w.here.set(loginKey("gone"), login("gone", "g1", Date.now()));
    const engine = await onAndSynced();
    await w.cycles(engine);
    const syncId = engine.useSync.getState().profiles.default.syncId;
    const b = passwordMac(`p:${syncId}`);
    await b.sync();
    const realRead = native.read;
    native.read = async (f, scope, known) => {
      const listing = await realRead(f, scope, known);
      return { ...listing, pending: [...listing.pending, "still-downloading"] };
    };
    try {
      w.later(2);
      w.here.set(loginKey("edit"), login("edit", "e2 here", Date.now()));
      w.here.set(loginKey("new"), login("new", "n1", Date.now()));
      w.here.delete(loginKey("gone"));
      await w.cycles(engine, 2);
      await b.sync();
      assert.equal(b.store.get(syncKey("edit"))?.p, "e2 here", "the edit went out");
      assert.equal(b.store.get(syncKey("new"))?.p, "n1", "the addition went out");
      assert.ok(b.store.has(syncKey("gone")), "the deletion waits for the download");
    } finally {
      native.read = realRead;
    }
  }));

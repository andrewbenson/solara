import "../../../../../../native/SolaraKit/Scripts/legacy-bookmark-harness.mjs";
import assert from "node:assert/strict";
import { test } from "node:test";
const { fixedBy } = await import('../switchOn.mjs');
const { world, onAndSynced, passwordMac, loginKey, syncKey, login, SITE, native, folder, shell, settle, loginDataMark } = await import('./world.mjs');

test("R4-unforced-is-unforced: timer cycles read Login Data about every other 15 s cycle, not every cycle", () =>
  world(async (w) => {
    w.here.set(loginKey("me"), login("me", "v1", Date.now()));
    const engine = await onAndSynced();
    await w.cycles(engine);
    let reads = 0;
    let readable = true;
    Object.defineProperty(w, "readable", { configurable: true, get: () => (reads++, readable), set: (v) => (readable = v) });
    await w.unforced(8);
    assert.ok(reads >= 2 && reads <= 5, `the 30 s interval gates the 15 s timer (${reads} reads in 8 cycles)`);
  }));

test("R4-starve: an edit to a synced login goes out while the other Mac keeps the folder busy with slow-downloading tab files", () =>
  world(async (w) => {
    w.here.set(loginKey("me"), login("me", "v1", Date.now()));
    const engine = await onAndSynced();
    await w.cycles(engine);
    const syncId = engine.useSync.getState().profiles.default.syncId;
    const b = passwordMac(`p:${syncId}`);
    await b.sync();
    const seenAt = new Map();
    const realRead = native.read;
    native.read = async (f, scope, known) => {
      const listing = await realRead(f, scope, known);
      const now = Date.now();
      const hide = (id) => {
        if (!seenAt.has(id)) seenAt.set(id, now);
        return now - seenAt.get(id) < 120_000;
      };
      const late = listing.files.filter((x) => hide(x.id)).map((x) => x.id);
      return { ...listing, files: listing.files.filter((x) => !late.includes(x.id)), present: listing.present.filter((id) => !late.includes(id)), pending: [...listing.pending, ...late] };
    };
    try {
      w.here.set(loginKey("me"), login("me", "v2 here", Date.now()));
      for (let i = 0; i < 40; i++) {
        if (i % 4 === 0) {
          b.store.set(`pw:${SITE}\nnoise${i}`, { o: SITE, u: `noise${i}`, p: `n${i}` });
          await b.sync();
        }
        await w.unforced(1);
      }
    } finally {
      native.read = realRead;
    }
    const mine = folder.size && [...folder.values()].map((f) => JSON.parse(f.payload)).filter((f) => f.device !== "pwMac").flatMap((f) => f.ops ?? []).filter((op) => op.k === syncKey("me")).map((op) => op.v?.p);
    assert.ok(mine.includes("v2 here"), `the edit went out within 10 minutes of timer cycles (sent: ${JSON.stringify(mine)})`);
  }));

test("R4-starve-delete-control: an edit to a synced login goes out while the other Mac keeps the folder busy with slow-downloading tab files", fixedBy("step 3"), () =>
  world(async (w) => {
    w.here.set(loginKey("me"), login("me", "v1", Date.now()));
    const engine = await onAndSynced();
    await w.cycles(engine);
    const syncId = engine.useSync.getState().profiles.default.syncId;
    const b = passwordMac(`p:${syncId}`);
    await b.sync();
    const seenAt = new Map();
    const realRead = native.read;
    native.read = async (f, scope, known) => {
      const listing = await realRead(f, scope, known);
      const now = Date.now();
      const hide = (id) => {
        if (!seenAt.has(id)) seenAt.set(id, now);
        return now - seenAt.get(id) < 120_000;
      };
      const late = listing.files.filter((x) => hide(x.id)).map((x) => x.id);
      return { ...listing, files: listing.files.filter((x) => !late.includes(x.id)), present: listing.present.filter((id) => !late.includes(id)), pending: [...listing.pending, ...late] };
    };
    try {
      w.here.delete(loginKey("me"));
      for (let i = 0; i < 40; i++) {
        if (i % 4 === 0) {
          b.store.set(`pw:${SITE}\nnoise${i}`, { o: SITE, u: `noise${i}`, p: `n${i}` });
          await b.sync();
        }
        await w.unforced(1);
      }
    } finally {
      native.read = realRead;
    }
    const mine = folder.size && [...folder.values()].map((f) => JSON.parse(f.payload)).filter((f) => f.device !== "pwMac").flatMap((f) => f.ops ?? []).filter((op) => op.k === syncKey("me")).map((op) => op.v?.p);
    assert.ok(!mine.includes(undefined), `control: the deletion is held while files keep arriving within 10 minutes of timer cycles (sent: ${JSON.stringify(mine)})`);
  }));

test("R4-starve-delete-long: an edit to a synced login goes out while the other Mac keeps the folder busy with slow-downloading tab files", fixedBy("step 3"), () =>
  world(async (w) => {
    w.here.set(loginKey("me"), login("me", "v1", Date.now()));
    const engine = await onAndSynced();
    await w.cycles(engine);
    const syncId = engine.useSync.getState().profiles.default.syncId;
    const b = passwordMac(`p:${syncId}`);
    await b.sync();
    const seenAt = new Map();
    const realRead = native.read;
    native.read = async (f, scope, known) => {
      const listing = await realRead(f, scope, known);
      const now = Date.now();
      const hide = (id) => {
        if (!seenAt.has(id)) seenAt.set(id, now);
        return now - seenAt.get(id) < 120_000;
      };
      const late = listing.files.filter((x) => hide(x.id)).map((x) => x.id);
      return { ...listing, files: listing.files.filter((x) => !late.includes(x.id)), present: listing.present.filter((id) => !late.includes(id)), pending: [...listing.pending, ...late] };
    };
    try {
      w.here.delete(loginKey("me"));
      for (let i = 0; i < 240; i++) {
        if (i % 4 === 0) {
          b.store.set(`pw:${SITE}\nnoise${i}`, { o: SITE, u: `noise${i}`, p: `n${i}` });
          await b.sync();
        }
        await w.unforced(1);
      }
    } finally {
      native.read = realRead;
    }
    const files = [...folder.values()].map((f) => JSON.parse(f.payload)).filter((f) => f.device !== "pwMac");
    const sent = [...files.flatMap((f) => f.ops ?? []).filter((op) => op.k === syncKey("me")).map((op) => op.v), ...files.flatMap((f) => (f.records?.[syncKey("me")] ? [f.records[syncKey("me")].v] : []))];
    await b.sync();
    assert.ok(sent.includes(null) && !b.store.has(syncKey("me")), `the deletion goes out within an hour even while B keeps writing a file a minute within 10 minutes of timer cycles (sent in logs and snapshots: ${JSON.stringify(sent)}; B has ${JSON.stringify(b.store.get(syncKey("me")))})`);
  }));

test("R4-confirm-during-download: confirming held deletions while a file is downloading sends them, without asking again", fixedBy("step 3"), () =>
  world(async (w) => {
    for (let i = 0; i < 10; i++) w.here.set(loginKey(`u${i}`), login(`u${i}`, `p${i}`, Date.now()));
    const engine = await onAndSynced();
    const syncId = engine.useSync.getState().profiles.default.syncId;
    const b = passwordMac(`p:${syncId}`);
    await b.sync();
    w.later(60);
    for (let i = 0; i < 6; i++) w.here.delete(loginKey(`u${i}`));
    await w.cycles(engine);
    assert.equal(engine.useSync.getState().heldPasswords?.default, 6, "control: held");
    const realRead = native.read;
    let pendingFor = 0;
    native.read = async (f, scope, known) => {
      const listing = await realRead(f, scope, known);
      return pendingFor-- > 0 ? { ...listing, pending: [...listing.pending, "slow"] } : listing;
    };
    try {
      pendingFor = 1;
      engine.resolveHeldPasswords("default", "confirm");
      await settle(60);
      await w.cycles(engine, 1);
      pendingFor = 0;
      await w.cycles(engine, 3);
    } finally {
      native.read = realRead;
    }
    await b.sync();
    const asked = engine.useSync.getState().heldPasswords?.default ?? 0;
    assert.equal(asked, 0, `the prompt doesn't come back after Confirm (held ${asked})`);
    assert.equal(b.store.size, 4, `the six deletions go out (B has ${b.store.size})`);
  }));

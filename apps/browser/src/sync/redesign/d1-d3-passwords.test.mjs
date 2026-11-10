import "../../../../../native/SolaraKit/Scripts/legacy-bookmark-harness.mjs";
import assert from "node:assert/strict";
import { test } from "node:test";
const { fixedBy } = await import('./switchOn.mjs');
const { shell, settle, launch, reset, onAndSynced, passwordMac, native, realReadPasswords, realSetTimeout, restoreDocs } = await import('./harness.mjs');
const { sealedState } = await import('../sealedState.mjs');

const SITE = "https://site.example";
const loginKey = (user) => `${SITE}\n${user}`;
const syncKey = (user) => `pw:${loginKey(user)}`;
const login = (user, password, at) => ({ origin: `${SITE}/`, url: `${SITE}/`, username: user, password, created: at, modified: at });

async function passwordsWorld(run) {
  reset();
  const here = new Map();
  const world = { here, readable: true, offset: 0 };
  shell.passwordStores.set(null, here);
  native.readPasswords = async () => (world.readable ? [...here.values()] : null);
  const realST = globalThis.setTimeout;
  const realNow = Date.now;
  globalThis.setTimeout = (fn, ms) => (ms === 250 ? realSetTimeout(fn, 0) : 0);
  Date.now = () => realNow() + world.offset;
  world.later = (minutes = 1) => (world.offset += minutes * 60_000);
  world.cycles = async (engine, n = 3) => {
    for (let i = 0; i < n; i++) {
      world.later();
      await engine.syncNow();
      await settle(60);
    }
  };
  try {
    await run(world);
  } finally {
    Date.now = realNow;
    globalThis.setTimeout = realST;
    native.readPasswords = realReadPasswords;
  }
}

test("D1a: a username-only rename here, with the old date, survives an older tombstone of the new key and an older deletion elsewhere", () =>
  passwordsWorld(async (w) => {
    const t0 = Date.now() - 86_400_000;
    w.here.set(loginKey("old"), login("old", "secret", t0));
    const engine = await onAndSynced();
    const syncId = engine.useSync.getState().profiles.default.syncId;
    const b = passwordMac(`p:${syncId}`);
    await b.sync();
    b.store.set(syncKey("new"), { o: SITE, u: "new", p: "x" });
    await b.sync();
    b.store.delete(syncKey("new"));
    await b.sync();
    await w.cycles(engine, 1);
    w.later(30);
    w.here.delete(loginKey("old"));
    w.here.set(loginKey("new"), login("new", "secret", t0));
    await w.cycles(engine);
    await b.sync();
    assert.equal(b.store.get(syncKey("new"))?.p, "secret", `the renamed login reaches B (B has ${JSON.stringify(b.store.get(syncKey("new")))})`);
    assert.equal(w.here.get(loginKey("new"))?.password, "secret", "and stays here");
  }));

test("D1b: a password changed here wins over another Mac's earlier change stamped by a clock an hour ahead", () =>
  passwordsWorld(async (w) => {
    w.here.set(loginKey("me"), login("me", "v1", Date.now()));
    const engine = await onAndSynced();
    const syncId = engine.useSync.getState().profiles.default.syncId;
    const b = passwordMac(`p:${syncId}`);
    await b.sync();
    const realNow = Date.now;
    Date.now = () => realNow() + 3_600_000;
    b.store.set(syncKey("me"), { o: SITE, u: "me", p: "from-B-ahead" });
    await b.sync();
    Date.now = realNow;
    await w.cycles(engine, 1);
    w.later(10);
    w.here.set(loginKey("me"), login("me", "changed-here-later", Date.now()));
    await w.cycles(engine);
    await b.sync();
    assert.equal(b.store.get(syncKey("me"))?.p, "changed-here-later", `the later real change wins (B has ${b.store.get(syncKey("me"))?.p})`);
  }));

test("D2a: Login Data replaced by a copy without most logins doesn't delete them everywhere", fixedBy("step 3"), () =>
  passwordsWorld(async (w) => {
    for (let i = 0; i < 10; i++) w.here.set(loginKey(`u${i}`), login(`u${i}`, `p${i}`, Date.now()));
    const engine = await onAndSynced();
    const syncId = engine.useSync.getState().profiles.default.syncId;
    const b = passwordMac(`p:${syncId}`);
    await b.sync();
    assert.equal(b.store.size, 10, "control: B has all ten");
    for (let i = 2; i < 10; i++) w.here.delete(loginKey(`u${i}`));
    await w.cycles(engine);
    await b.sync();
    assert.equal(b.store.size, 10, `B keeps all ten logins (B has ${b.store.size})`);
  }));

test("D2b: a deletion noticed after the keychain was unreadable loses to a newer change made elsewhere meanwhile", fixedBy("step 3"), () =>
  passwordsWorld(async (w) => {
    w.here.set(loginKey("me"), login("me", "v1", Date.now()));
    const engine = await onAndSynced();
    const syncId = engine.useSync.getState().profiles.default.syncId;
    const b = passwordMac(`p:${syncId}`);
    await b.sync();
    w.readable = false;
    w.here.delete(loginKey("me"));
    await w.cycles(engine, 1);
    w.later(60);
    b.store.set(syncKey("me"), { o: SITE, u: "me", p: "v2-from-B" });
    await b.sync();
    w.later(60);
    w.readable = true;
    await w.cycles(engine);
    await b.sync();
    assert.equal(b.store.get(syncKey("me"))?.p, "v2-from-B", `B's newer change survives (B has ${JSON.stringify(b.store.get(syncKey("me")))})`);
    assert.equal(w.here.get(loginKey("me"))?.password, "v2-from-B", "and comes back here");
  }));

test("D2c: a healthy relaunch republishes no unchanged login", () =>
  passwordsWorld(async (w) => {
    for (let i = 0; i < 5; i++) w.here.set(loginKey(`u${i}`), login(`u${i}`, `p${i}`, Date.now() - 86_400_000));
    const engine = await onAndSynced();
    await w.cycles(engine, 1);
    const before = shell.docs.get("sync-state.nns");
    const again = await launch();
    again.startSync();
    await settle();
    const written = [];
    const realWrite = native.write;
    native.write = async (folder, scope, payload) => (written.push(...(JSON.parse(payload).ops ?? []).filter((op) => op.k.startsWith("pw:"))), realWrite(folder, scope, payload));
    try {
      await w.cycles(again);
    } finally {
      native.write = realWrite;
    }
    void before;
    assert.deepEqual(written, [], "no login is republished");
  }));

test("D3: with its state lost, a login B changed meanwhile is applied here and the passwords type settles", () =>
  passwordsWorld(async (w) => {
    w.here.set(loginKey("me"), login("me", "v1", Date.now() - 86_400_000));
    const engine = await onAndSynced();
    const syncId = engine.useSync.getState().profiles.default.syncId;
    const b = passwordMac(`p:${syncId}`);
    await b.sync();
    await w.cycles(engine, 1);
    b.store.set(syncKey("me"), { o: SITE, u: "me", p: "v2-from-B" });
    await b.sync();
    shell.docs.set("sync-state.nns", "not-sealed-by-this-key");
    const again = await launch();
    again.startSync();
    await settle();
    await w.cycles(again, 4);
    await b.sync();
    assert.equal(w.here.get(loginKey("me"))?.password, "v2-from-B", `B's change is applied here (here: ${w.here.get(loginKey("me"))?.password})`);
    assert.equal(b.store.get(syncKey("me"))?.p, "v2-from-B");
    const sealed = sealedState(shell.docs)[`p:${syncId}`];
    assert.ok(!sealed.rebuild || sealed.rebuild.settled?.includes("pw:"), `the passwords type settles (${JSON.stringify(sealed.rebuild)})`);
  }));

test("Q3-family: a state rolled back past a password it had taken resends nothing over B's newer one", fixedBy("step 3"), () =>
  passwordsWorld(async (w) => {
    w.here.set(loginKey("me"), login("me", "v1", Date.now() - 86_400_000));
    const engine = await onAndSynced();
    const syncId = engine.useSync.getState().profiles.default.syncId;
    const b = passwordMac(`p:${syncId}`);
    await b.sync();
    await w.cycles(engine, 1);
    const older = new Map(shell.docs);
    b.store.set(syncKey("me"), { o: SITE, u: "me", p: "v2" });
    await b.sync();
    await w.cycles(engine, 2);
    assert.equal(w.here.get(loginKey("me"))?.password, "v2", "control: this Mac took v2");
    b.store.set(syncKey("me"), { o: SITE, u: "me", p: "v3" });
    await b.sync();
    restoreDocs(older);
    const again = await launch();
    again.startSync();
    await settle();
    await w.cycles(again);
    await b.sync();
    assert.equal(b.store.get(syncKey("me"))?.p, "v3", `B's newer password survives (B has ${b.store.get(syncKey("me"))?.p})`);
  }));

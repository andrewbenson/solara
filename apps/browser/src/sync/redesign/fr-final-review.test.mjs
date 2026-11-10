import "../../../../../native/SolaraKit/Scripts/legacy-bookmark-harness.mjs";
import assert from "node:assert/strict";
import { test } from "node:test";
const { fixedBy } = await import('./switchOn.mjs');
const { shell, S, settle, launch, reset, onAndSynced, otherMac, passwordMac, native, realReadPasswords, realSetTimeout, files, titles, bookmarkOps, sync, rawTransport , loginDataMark } = await import('./harness.mjs');

const SITE = "https://site.example";
const loginKey = (user) => `${SITE}\n${user}`;
const syncKey = (user) => `pw:${loginKey(user)}`;
const login = (user, password, modified) => ({ origin: `${SITE}/`, url: `${SITE}/`, username: user, password, created: modified, modified });

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

test("FR1: Login Data restored in place from one ledger write ago, dropping 30 of 70 logins applied in that write, deletes none of them elsewhere", fixedBy("step 3"), () =>
  passwordsWorld(async (w) => {
    for (let i = 0; i < 40; i++) w.here.set(loginKey(`old${i}`), login(`old${i}`, `p${i}`, Date.now()));
    const engine = await onAndSynced();
    const syncId = engine.useSync.getState().profiles.default.syncId;
    const b = passwordMac(`p:${syncId}`);
    await b.sync();
    const backup = new Map([...w.here].map(([k, v]) => [k, { ...v }]));
    const markInBackup = loginDataMark.value;
    for (let i = 0; i < 30; i++) b.store.set(syncKey(`new${i}`), { o: SITE, u: `new${i}`, p: `n${i}` });
    await b.sync();
    await w.cycles(engine);
    assert.equal(w.here.size, 70, "control: this Mac applied B's 30 logins in one go");
    w.here.clear();
    for (const [k, v] of backup) w.here.set(k, v);
    loginDataMark.value = markInBackup;
    await w.cycles(engine);
    await b.sync();
    assert.equal(b.store.size, 70, `B keeps all 70 (B has ${b.store.size})`);
  }));

test("FR2: a user going back to an earlier password on purpose is published", () =>
  passwordsWorld(async (w) => {
    w.here.set(loginKey("me"), login("me", "first", Date.now()));
    const engine = await onAndSynced();
    const syncId = engine.useSync.getState().profiles.default.syncId;
    const b = passwordMac(`p:${syncId}`);
    await b.sync();
    w.later(10);
    w.here.set(loginKey("me"), login("me", "second", Date.now()));
    await w.cycles(engine);
    w.later(10);
    w.here.set(loginKey("me"), login("me", "first", Date.now()));
    await w.cycles(engine);
    await b.sync();
    assert.equal(b.store.get(syncKey("me"))?.p, "first", `the deliberate revert reaches B (B has ${b.store.get(syncKey("me"))?.p})`);
  }));

test("FR3 (RR4): a rename made elsewhere at 9:00 that arrives at 10:30 wins here, even across this Mac's losses after it last agreed with the folder at 10:00", async () => {
  reset();
  const realNow = Date.now;
  const at = (minutes) => (Date.now = () => realNow() + minutes * 60_000);
  try {
    const engine = await onAndSynced();
    const syncId = engine.useSync.getState().profiles.default.syncId;
    const c = otherMac(`p:${syncId}`);
    await c.sync();
    const [key, value] = [...c.store].find(([, v]) => v.t === "One");
    at(0);
    c.store.set(key, { ...value, t: "Renamed on C at 9:00" });
    const late = sync.emptyScope();
    void late;
    const realWrite = rawTransport.write;
    let held = null;
    rawTransport.write = async (scope, payload) => ((held = { scope, payload }), "held");
    await c.sync();
    rawTransport.write = realWrite;
    at(60);
    for (let i = 0; i < 2; i++) await engine.syncNow();
    await settle();
    at(90);
    await realWrite(held.scope, held.payload);
    at(120);
    shell.docs.delete("sync-journal.nns");
    const mark = files().length;
    const again = await launch();
    again.startSync();
    await settle();
    for (let i = 0; i < 3; i++) await again.syncNow();
    await settle();
    assert.ok(titles().includes("Renamed on C at 9:00"), `C's late rename stands here (here: ${titles()})`);
    const sent = files().slice(mark).filter(({ scope }) => scope === `p:${syncId}`).flatMap(({ file }) => file.ops ?? []).filter((op) => op.k === key);
    assert.deepEqual(sent.map((op) => op.v?.t), [], "and this Mac sends nothing for it after the relaunch");
  } finally {
    Date.now = realNow;
  }
});

test("FR4: a rebuild whose snapshot is still downloading after ten minutes removes no local bookmark it hasn't seen arrive", async () => {
  reset();
  const realNow = Date.now;
  try {
    const engine = await onAndSynced();
    const syncId = engine.useSync.getState().profiles.default.syncId;
    for (const t of ["Two", "Three"]) S().addBookmark({ profileId: "default", url: `https://${t.toLowerCase()}.example/`, title: t });
    await engine.syncNow();
    await settle();
    const ours = new Set(files().filter((f) => f.scope === `p:${syncId}`).map((f) => f.payload));
    const realRead = native.read;
    native.read = async (...args) => {
      const listing = await realRead(...args);
      const stuck = listing.files.filter((f) => ours.has(f.payload));
      return { ...listing, files: listing.files.filter((f) => !ours.has(f.payload)), pending: [...listing.pending, ...stuck.map((f) => f.id)] };
    };
    try {
      shell.docs.set("sync-state.nns", "not-sealed-by-this-key");
      const again = await launch();
      again.startSync();
      await settle();
      for (const minutes of [0, 11, 30]) {
        Date.now = () => realNow() + minutes * 60_000;
        for (let i = 0; i < 2; i++) await again.syncNow();
        await settle();
      }
      assert.deepEqual(titles(), ["One", "Three", "Two"], "nothing still downloading is removed here");
      assert.ok(!bookmarkOps(syncId).some((op) => op.v === null), "and nothing is published as deleted");
    } finally {
      native.read = realRead;
    }
  } finally {
    Date.now = realNow;
  }
});

test("FR5: a pinned tab's page title changing here doesn't send its old group and position over a move made elsewhere", { todo: "step 6" }, async () => {
  reset();
  S().createWindow();
  const engine = await onAndSynced();
  const syncId = engine.useSync.getState().profiles.default.syncId;
  const w = S().windowOrder[0];
  const tab = S().newTab(w, { url: "https://pinned.example/" });
  S().togglePin(tab);
  await engine.syncNow();
  await settle();
  const store = new Map();
  const state = sync.emptyScope();
  state.joined = true;
  const clock = new sync.Clock("pinMac");
  const adapter = { prefix: "pin:t:", extract: () => ({ values: new Map(store) }), apply: (visible, changed) => { for (const k of changed) visible.has(k) ? store.set(k, visible.get(k)) : store.delete(k); } };
  const b = () => sync.syncScope({ scope: `p:${syncId}`, state, transport: rawTransport, adapters: [adapter], clock, device: "pinMac" });
  await b();
  const [key, value] = [...store].find(([, v]) => v.u === "https://pinned.example/") ?? [];
  assert.ok(key, "control: B has the pin");
  store.set(key, { ...value, pos: "z", g: null });
  await b();
  const realNow = Date.now;
  Date.now = () => realNow() + 60_000;
  try {
    S().navigated(tab, { url: "https://pinned.example/", title: "A new page title" }, {});
    for (let i = 0; i < 3; i++) await engine.syncNow();
    await settle();
  } finally {
    Date.now = realNow;
  }
  await b();
  assert.equal(store.get(key)?.pos, "z", `B's move stands (B has pos ${store.get(key)?.pos})`);
});

test("FR6: Solara always launches Chrome with --user-data-dir, so Chrome never deletes undecryptable logins on its own", async () => {
  const fs = await import("node:fs");
  const host = fs.readFileSync(new URL("../../../../../packages/solaracore/ios/SolaraCoreHost.mm", import.meta.url), "utf8");
  const delegate = fs.readFileSync(new URL("../../../../../engine/solaracore/src/solara/core/ac_main_delegate.cc", import.meta.url), "utf8");
  assert.match(host, /"--user-data-dir=" \+ std::string\(gDataDirectory\.UTF8String\)/, "the host passes --user-data-dir");
  assert.match(delegate, /CHECK\(!dir\.empty\(\)\) << "SolaraCore needs --user-data-dir"/, "and the engine refuses to start without it");
});
